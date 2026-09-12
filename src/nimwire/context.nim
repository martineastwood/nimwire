## Request-scoped context and explicit application state handles.

import std/[asyncdispatch, base64, json, options, sysrand, tables, times]

import ./core

type
  McpTransportKind* = enum
    mcpTransportUnknown
    mcpTransportStdio
    mcpTransportHttp

  McpTransportInfo* = object
    kind*: McpTransportKind
    name*: string
    endpoint*: string
    remoteAddress*: string

  McpPrincipal* = ref object
    subject*: string
    claims*: JsonNode

  McpCancellation* = ref object
    cancelled: bool

  McpLogger* = proc (level: McpLogLevel, message: string) {.closure.}
  McpProgressReporter* = proc (progress, total: float,
                               message: string): Future[void] {.closure.}
  McpRequestStateSealer* = proc (payload: JsonNode,
                                 context: McpContext): string {.closure.}
  McpRequestStateVerifier* = proc (state: string,
                                   context: McpContext): JsonNode {.closure.}

  McpStateClaim* = object
    subject*: string
    value*: JsonNode
    expiresAt*: int64

  McpStateStore* = ref object
    entries: Table[string, McpStateClaim]
    ttlSeconds: int64
    maxEntries: int

  McpContext* = ref object
    ## This object is created once per request and must not be shared.
    requestId*: McpId
    methodName*: string
    metadata*: McpRequestMeta
    cancellation*: McpCancellation
    progress*: McpProgressReporter
    logger*: McpLogger
    transport*: McpTransportInfo
    principal*: McpPrincipal
    extensionState*: JsonNode
    completionArguments*: JsonNode
    inputResponses*: JsonNode
    hasRequestState*: bool
    requestState*: string
    requestStatePayload*: JsonNode
    requestStateSealer*: McpRequestStateSealer
    requestStateVerifier*: McpRequestStateVerifier
    stateStore*: McpStateStore
    hasInputRequired*: bool
    inputRequired*: McpResult

proc newMcpPrincipal*(subject: string, claims: JsonNode = nil): McpPrincipal =
  if subject.len == 0:
    raise newMcpError("principal subject must not be empty")
  McpPrincipal(subject: subject,
    claims: if claims.isNil: newJObject() else: claims)

proc newMcpCancellation*(): McpCancellation =
  McpCancellation(cancelled: false)

proc cancel*(cancellation: McpCancellation) =
  if not cancellation.isNil: cancellation.cancelled = true

proc isCancelled*(cancellation: McpCancellation): bool =
  not cancellation.isNil and cancellation.cancelled

proc checkCancelled*(cancellation: McpCancellation) =
  if cancellation.isCancelled:
    raise newMcpError("MCP request cancelled", mcpRequestCancelledCode)

proc newMcpStateStore*(ttlSeconds = 900, maxEntries = 10000): McpStateStore =
  if ttlSeconds < 1:
    raise newMcpError("state handle ttlSeconds must be positive")
  if maxEntries < 1:
    raise newMcpError("state handle maxEntries must be positive")
  McpStateStore(entries: initTable[string, McpStateClaim](),
    ttlSeconds: ttlSeconds.int64, maxEntries: maxEntries)

proc purgeExpired(store: McpStateStore, now: int64) =
  var expired: seq[string]
  for handle, entry in store.entries:
    if entry.expiresAt <= now: expired.add handle
  for handle in expired:
    store.entries.del(handle)

proc randomStateHandle(store: McpStateStore): string =
  while true:
    result = "nimwire." & encode(urandom(32), safe = true)
    if result notin store.entries: return

proc mintStateHandle*(store: McpStateStore, subject: string,
                      value: JsonNode): string =
  if store.isNil: raise newMcpError("state store must not be nil")
  let now = getTime().toUnix
  store.purgeExpired(now)
  if store.entries.len >= store.maxEntries:
    raise newMcpError("state handle store is full")
  result = store.randomStateHandle()
  store.entries[result] = McpStateClaim(subject: subject, value: value,
    expiresAt: now + store.ttlSeconds)

proc verifyStateHandle*(store: McpStateStore, handle, subject: string):
    Option[McpStateClaim] =
  if store.isNil or handle.len == 0: return none(McpStateClaim)
  let now = getTime().toUnix
  if handle notin store.entries: return none(McpStateClaim)
  let entry = store.entries[handle]
  if entry.expiresAt <= now:
    store.entries.del(handle)
    return none(McpStateClaim)
  if entry.subject != subject: return none(McpStateClaim)
  some(entry)

proc revokeStateHandle*(store: McpStateStore, handle: string): bool =
  if store.isNil or handle notin store.entries: return false
  store.entries.del(handle)
  true

proc newMcpContext*(request: McpRpcRequest,
                    transport = McpTransportInfo(),
                    cancellation: McpCancellation = nil,
                    principal: McpPrincipal = nil,
                    extensionState: JsonNode = nil,
                    stateStore: McpStateStore = nil,
                    logger: McpLogger = nil,
                    progress: McpProgressReporter = nil,
                    requestStateSealer: McpRequestStateSealer = nil,
                    requestStateVerifier: McpRequestStateVerifier = nil): McpContext =
  McpContext(
    requestId: if request.kind == mcpRequest: request.id else:
      McpId(kind: mcpNullId),
    methodName: request.methodName,
    metadata: request.params.meta,
    cancellation: if cancellation.isNil: newMcpCancellation() else: cancellation,
    progress: progress,
    logger: logger,
    transport: transport,
    principal: principal,
    extensionState: if extensionState.isNil: newJObject() else: extensionState,
    completionArguments: newJObject(),
    inputResponses: if "inputResponses" in request.params.values:
      request.params.values["inputResponses"] else: newJObject(),
    hasRequestState: "requestState" in request.params.values,
    requestState: if "requestState" in request.params.values:
      request.params.values["requestState"].getStr else: "",
    requestStateSealer: requestStateSealer,
    requestStateVerifier: requestStateVerifier,
    stateStore: stateStore)

proc cancel*(context: McpContext) =
  if not context.isNil: context.cancellation.cancel()

proc isCancelled*(context: McpContext): bool =
  not context.isNil and context.cancellation.isCancelled

proc checkCancelled*(context: McpContext) =
  if context.isNil:
    raise newMcpError("MCP context must not be nil")
  context.cancellation.checkCancelled()

proc sealRequestState*(context: McpContext, payload: JsonNode): string =
  if context.isNil or context.requestStateSealer.isNil:
    raise newMcpError("MCP request state sealer is not configured")
  result = context.requestStateSealer(payload, context)
  if result.len == 0:
    raise newMcpError("MCP request state sealer returned an empty state")

proc verifyRequestState*(context: McpContext): JsonNode =
  if context.isNil or not context.hasRequestState or
      context.requestStateVerifier.isNil:
    return nil
  result = context.requestStateVerifier(context.requestState, context)
  if result.isNil:
    raise newMcpError("MCP request state verification failed")
  context.requestStatePayload = result

proc requireInput*(context: McpContext, value: McpResult) =
  if context.isNil:
    raise newMcpError("MCP context must not be nil")
  if value.resultType != mcpInputRequired:
    raise newMcpError("input requirement must use mcpInputRequired")
  context.inputRequired = value
  context.hasInputRequired = true

proc inputResponse*(context: McpContext, key: string): JsonNode =
  if context.isNil or context.inputResponses.isNil or
      context.inputResponses.kind != JObject or key notin context.inputResponses:
    return nil
  context.inputResponses[key]

proc log*(context: McpContext, level: McpLogLevel, message: string) =
  if not context.isNil and not context.logger.isNil:
    context.logger(level, message)

proc reportProgress*(context: McpContext, progress: float, total = -1.0,
                     message = ""): Future[void] {.async.} =
  if context.isNil:
    raise newMcpError("MCP context must not be nil")
  context.checkCancelled()
  if not context.progress.isNil:
    await context.progress(progress, total, message)

proc mintStateHandle*(context: McpContext, value: JsonNode): string =
  if context.isNil or context.stateStore.isNil:
    raise newMcpError("MCP context has no state store")
  let subject = if context.principal.isNil: "" else: context.principal.subject
  context.stateStore.mintStateHandle(subject, value)

proc verifyStateHandle*(context: McpContext,
                        handle: string): Option[McpStateClaim] =
  if context.isNil or context.stateStore.isNil:
    return none(McpStateClaim)
  let subject = if context.principal.isNil: "" else: context.principal.subject
  context.stateStore.verifyStateHandle(handle, subject)
