## Composable request middleware for tool handlers.

import std/[asyncdispatch, json, times]

import ./context
import ./core

type
  McpToolNext* = proc (): Future[McpToolResult] {.closure.}
  McpToolMiddleware* = proc (name: string, arguments: JsonNode,
                             context: McpContext,
                             next: McpToolNext): Future[McpToolResult] {.closure.}
  McpToolAuthorization* = proc (name: string,
                                principal: McpPrincipal): bool {.closure.}
  McpToolPolicy* = proc (name: string, arguments: JsonNode,
                         context: McpContext): bool {.closure.}
  McpToolValidation* = proc (name: string, arguments: JsonNode,
                             context: McpContext) {.closure.}
  McpToolTimingHook* = proc (name: string, durationMs: float) {.closure.}
  McpToolRetryPredicate* = proc (error: ref CatchableError): bool {.closure.}
  McpToolApprovalDecision* = enum
    mcpApprovalAllow
    mcpApprovalDeny
  McpToolApprovalPolicy* = proc (name: string, arguments: JsonNode,
                                context: McpContext):
                                Future[McpToolApprovalDecision] {.closure.}
  McpSyncToolApprovalPolicy* = proc (name: string, arguments: JsonNode,
                                     context: McpContext):
                                     McpToolApprovalDecision {.closure.}

proc mcpAuthMiddleware*(authorize: McpToolAuthorization): McpToolMiddleware =
  if authorize.isNil:
    raise newMcpError("tool authorization hook must not be nil")
  result = proc (name: string, arguments: JsonNode, context: McpContext,
                 next: McpToolNext): Future[McpToolResult] {.async.} =
    discard arguments
    if context.isNil or not authorize(name, context.principal):
      raise newMcpError("tool authorization denied")
    await next()

proc mcpValidationMiddleware*(validate: McpToolValidation): McpToolMiddleware =
  if validate.isNil:
    raise newMcpError("tool validation hook must not be nil")
  result = proc (name: string, arguments: JsonNode, context: McpContext,
                 next: McpToolNext): Future[McpToolResult] {.async.} =
    validate(name, arguments, context)
    await next()

proc mcpTimingMiddleware*(timing: McpToolTimingHook): McpToolMiddleware =
  if timing.isNil:
    raise newMcpError("tool timing hook must not be nil")
  result = proc (name: string, arguments: JsonNode, context: McpContext,
                 next: McpToolNext): Future[McpToolResult] {.async.} =
    let startedAt = epochTime()
    try:
      return await next()
    finally:
      try:
        timing(name, max(0.0, (epochTime() - startedAt) * 1000.0))
      except CatchableError:
        discard

proc defaultMcpRetry*(error: ref CatchableError): bool =
  if error of McpError:
    return cast[ref McpError](error).retryable
  false

proc mcpRetryMiddleware*(maxAttempts = 2, delayMs = 0,
                         retryOn: McpToolRetryPredicate = nil):
                         McpToolMiddleware =
  if maxAttempts < 1:
    raise newMcpError("tool retry maxAttempts must be positive")
  if delayMs < 0:
    raise newMcpError("tool retry delayMs must be non-negative")
  result = proc (name: string, arguments: JsonNode, context: McpContext,
                 next: McpToolNext): Future[McpToolResult] {.async.} =
    discard name
    discard arguments
    discard context
    var attempts = 0
    while true:
      try:
        let output = await next()
        if not output.isError or not output.retryable:
          return output
        inc attempts
        if attempts >= maxAttempts:
          return output
        if delayMs > 0:
          await sleepAsync(delayMs)
      except CatchableError as error:
        inc attempts
        let shouldRetry = if retryOn.isNil: defaultMcpRetry(error) else:
          retryOn(error)
        if attempts >= maxAttempts or not shouldRetry:
          raise
        if delayMs > 0:
          await sleepAsync(delayMs)

proc mcpPolicyMiddleware*(policy: McpToolPolicy): McpToolMiddleware =
  if policy.isNil:
    raise newMcpError("tool policy hook must not be nil")
  result = proc (name: string, arguments: JsonNode, context: McpContext,
                 next: McpToolNext): Future[McpToolResult] {.async.} =
    if not policy(name, arguments, context):
      raise newMcpError("tool policy denied")
    await next()

proc mcpApprovalMiddleware*(policy: McpToolApprovalPolicy): McpToolMiddleware =
  if policy.isNil:
    raise newMcpError("tool approval policy must not be nil")
  result = proc (name: string, arguments: JsonNode, context: McpContext,
                 next: McpToolNext): Future[McpToolResult] {.async.} =
    if (await policy(name, arguments, context)) == mcpApprovalDeny:
      raise newMcpError("tool approval denied")
    await next()

proc mcpApprovalMiddleware*(policy: McpSyncToolApprovalPolicy): McpToolMiddleware =
  if policy.isNil:
    raise newMcpError("tool approval policy must not be nil")
  let asyncPolicy: McpToolApprovalPolicy = proc (
      name: string, arguments: JsonNode, context: McpContext):
      Future[McpToolApprovalDecision] {.async.} =
    policy(name, arguments, context)
  mcpApprovalMiddleware(asyncPolicy)

proc runMcpToolMiddleware*(middlewares: seq[McpToolMiddleware], index: int,
                           name: string, arguments: JsonNode,
                           context: McpContext,
                           terminal: McpToolNext):
                           Future[McpToolResult] {.async.} =
  if index >= middlewares.len:
    return await terminal()
  let current = middlewares[index]
  let next: McpToolNext = proc (): Future[McpToolResult] {.async.} =
    await runMcpToolMiddleware(middlewares, index + 1, name, arguments,
      context, terminal)
  await current(name, arguments, context, next)
