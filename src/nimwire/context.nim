## Request-scoped context and explicit application state handles.

import std/[asyncdispatch, base64, json, options, sysrand, tables, times]

import ./core

type
  McpTransportKind* = enum
    mcpTransportUnknown
    mcpTransportStdio
    mcpTransportHttp
    mcpTransportWebSocket
    mcpTransportInProcess

  McpTransportInfo* = object
    kind*: McpTransportKind
    name*: string
    endpoint*: string
    remoteAddress*: string

  McpPrincipal* = ref object
    subject*: string
    issuer*: string
    scopes*: seq[string]
    claims*: JsonNode

  McpCancellation* = ref object
    cancelled: bool
    reason*: string
    signal: Future[void]

  McpLogger* = proc (level: McpLogLevel, message: string) {.closure.}
  McpProgressReporter* = proc (progress, total: float,
                               message: string): Future[void] {.closure.}
  McpNotificationSender* = proc (message: JsonNode): Future[void] {.closure.}
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
    correlationId*: string
    requestBytes*: int
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
    notificationSender*: McpNotificationSender
    hasProgressToken*: bool
    progressToken*: McpId
    deadlineAt*: float
    lastProgress*: float
    hasReportedProgress*: bool
    hasInputRequired*: bool
    inputRequired*: McpWireResult

proc newMcpPrincipal*(subject: string, claims: JsonNode = nil,
                      issuer = "", scopes: seq[string] = @[]): McpPrincipal =
  if subject.len == 0:
    raise newMcpError("principal subject must not be empty")
  McpPrincipal(subject: subject,
    issuer: issuer, scopes: scopes,
    claims: if claims.isNil: newJObject() else: claims)

proc newMcpCancellation*(): McpCancellation =
  McpCancellation(cancelled: false,
    signal: newFuture[void]("mcpCancellation"))

proc cancel*(cancellation: McpCancellation, reason = "") =
  if cancellation.isNil or cancellation.cancelled: return
  cancellation.cancelled = true
  cancellation.reason = reason
  if not cancellation.signal.finished: cancellation.signal.complete()

proc waitCancelled*(cancellation: McpCancellation): Future[void] =
  if cancellation.isNil:
    raise newMcpError("MCP cancellation must not be nil")
  cancellation.signal

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

proc newMcpCorrelationId*(): string =
  "nimwire.correlation." & encode(urandom(16), safe = true)

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
                    requestStateVerifier: McpRequestStateVerifier = nil,
                    notificationSender: McpNotificationSender = nil,
                    deadlineMs = 0, requestBytes = 0,
                    correlationId = ""): McpContext =
  let hasProgressToken = request.params.meta.hasProgressToken
  McpContext(
    requestId: if request.kind == mcpRequest: request.id else:
      McpId(kind: mcpNullId),
    correlationId: if correlationId.len > 0: correlationId else:
      newMcpCorrelationId(),
    requestBytes: max(0, requestBytes),
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
    stateStore: stateStore,
    notificationSender: notificationSender,
    hasProgressToken: hasProgressToken,
    progressToken: if hasProgressToken: request.params.meta.progressToken else:
      McpId(kind: mcpNullId),
    deadlineAt: if deadlineMs > 0: epochTime() + deadlineMs.float / 1000.0 else: 0.0)

proc cancel*(context: McpContext, reason = "") =
  if not context.isNil: context.cancellation.cancel(reason)

proc isCancelled*(context: McpContext): bool =
  not context.isNil and context.cancellation.isCancelled

proc checkCancelled*(context: McpContext) =
  if context.isNil:
    raise newMcpError("MCP context must not be nil")
  if context.deadlineAt > 0 and epochTime() >= context.deadlineAt:
    context.cancellation.cancel("deadline exceeded")
    raise newMcpError("MCP request timed out", mcpInternalErrorCode)
  context.cancellation.checkCancelled()

proc remainingTimeMs*(context: McpContext): int =
  if context.isNil or context.deadlineAt <= 0: return -1
  max(0, int((context.deadlineAt - epochTime()) * 1000.0))

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

proc requireInput*(context: McpContext, value: McpWireResult) =
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
  let minimum = if context.isNil or not context.metadata.hasLogLevel:
    mcpLogInfo else: context.metadata.logLevel
  if not context.isNil and level >= minimum and not context.logger.isNil:
    context.logger(level, message)

proc reportProgress*(context: McpContext, progress: float, total = -1.0,
                     message = ""): Future[void] {.async.} =
  if context.isNil:
    raise newMcpError("MCP context must not be nil")
  context.checkCancelled()
  if progress < 0 or total < -1 or (total >= 0 and progress > total):
    raise newMcpError("MCP progress values are invalid")
  if context.hasReportedProgress and progress <= context.lastProgress:
    raise newMcpError("MCP progress must increase")
  context.lastProgress = progress
  context.hasReportedProgress = true
  if not context.progress.isNil:
    await context.progress(progress, total, message)
  if context.hasProgressToken and not context.notificationSender.isNil:
    var params = %*{
      "progressToken": toJson(context.progressToken),
      "progress": progress
    }
    if total >= 0: params["total"] = %total
    if message.len > 0: params["message"] = %message
    await context.notificationSender(%*{
      "jsonrpc": mcpJsonRpcVersion,
      "method": "notifications/progress",
      "params": params
    })

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
