## Optional request observability hooks.

import std/json

import ./core
import ./context

type
  McpSpanHandle* = ref object
    ## Opaque application-owned state returned by a span start hook.
    state*: JsonNode

  McpRequestEvent* = object
    correlationId*: string
    requestId*: McpId
    methodName*: string
    transport*: McpTransportInfo
    hasTraceContext*: bool
    traceContext*: McpTraceContext
    hasLogLevel*: bool
    logLevel*: McpLogLevel
    durationMs*: float
    requestBytes*: int
    responseBytes*: int
    hasResultType*: bool
    resultType*: McpResultType
    errorCode*: int
    cancelled*: bool
    activeSubscriptions*: int

  McpRequestLogHook* = proc (event: McpRequestEvent) {.closure.}
  McpMetricsHook* = proc (event: McpRequestEvent) {.closure.}
  McpSpanStartHook* = proc (event: McpRequestEvent): McpSpanHandle {.closure.}
  McpSpanEndHook* = proc (span: McpSpanHandle, event: McpRequestEvent) {.closure.}

  McpObservability* = object
    ## All hooks are optional and remain independent of telemetry libraries.
    requestLog*: McpRequestLogHook
    metrics*: McpMetricsHook
    spanStart*: McpSpanStartHook
    spanEnd*: McpSpanEndHook

proc transportName(transport: McpTransportKind): string =
  case transport
  of mcpTransportUnknown: "unknown"
  of mcpTransportStdio: "stdio"
  of mcpTransportHttp: "http"

proc newMcpRequestEvent*(context: McpContext, methodName = "",
                         requestId = McpId(kind: mcpNullId)): McpRequestEvent =
  result.requestId = requestId
  result.methodName = methodName
  if context.isNil:
    result.correlationId = newMcpCorrelationId()
    return
  result.correlationId = if context.correlationId.len > 0:
    context.correlationId else: newMcpCorrelationId()
  result.requestId = context.requestId
  result.methodName = context.methodName
  result.transport = context.transport
  result.requestBytes = context.requestBytes
  result.hasTraceContext = context.metadata.hasTraceContext
  result.traceContext = context.metadata.traceContext
  result.hasLogLevel = context.metadata.hasLogLevel
  result.logLevel = context.metadata.logLevel

proc toJson*(event: McpRequestEvent): JsonNode =
  result = %*{
    "correlationId": event.correlationId,
    "requestId": toJson(event.requestId),
    "method": event.methodName,
    "transport": transportName(event.transport.kind),
    "durationMs": event.durationMs,
    "requestBytes": event.requestBytes,
    "responseBytes": event.responseBytes,
    "cancelled": event.cancelled,
    "activeSubscriptions": event.activeSubscriptions
  }
  if event.hasTraceContext:
    result["traceContext"] = toJson(event.traceContext)
  if event.hasLogLevel:
    result["logLevel"] = %event.logLevel.logLevelName
  if event.hasResultType:
    result["resultType"] = %event.resultType.resultTypeName
  if event.errorCode != 0:
    result["errorCode"] = %event.errorCode
