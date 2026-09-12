## Typed protocol values and JSON-RPC validation.

import std/[json, strutils]

const
  mcpProtocolVersion* = "2026-07-28"
  mcpJsonRpcVersion* = "2.0"
  mcpParseErrorCode* = -32700
  mcpInvalidRequestCode* = -32600
  mcpMethodNotFoundCode* = -32601
  mcpInvalidParamsCode* = -32602
  mcpInternalErrorCode* = -32603
  mcpRequestCancelledCode* = -32800
  mcpServerBusyCode* = -32029
  mcpHeaderMismatchCode* = -32020
  mcpUnsupportedProtocolVersionCode* = -32022
  mcpDefaultMaxMessageBytes* = 1024 * 1024
  mcpDefaultMaxNestingDepth* = 64
  mcpDefaultCompletionLimit* = 100

  mcpMetaProtocolVersionKey* = "io.modelcontextprotocol/protocolVersion"
  mcpMetaClientInfoKey* = "io.modelcontextprotocol/clientInfo"
  mcpMetaClientCapabilitiesKey* = "io.modelcontextprotocol/clientCapabilities"
  mcpMetaTraceContextKey* = "io.modelcontextprotocol/traceContext"
  mcpMetaLogLevelKey* = "io.modelcontextprotocol/logLevel"
  mcpMetaProgressTokenKey* = "progressToken"

type
  McpError* = object of CatchableError
    code*: int
    data*: JsonNode

  McpIdKind* = enum
    mcpStringId
    mcpIntegerId
    mcpNullId

  McpId* = object
    case kind*: McpIdKind
    of mcpStringId:
      stringValue*: string
    of mcpIntegerId:
      integerValue*: int64
    of mcpNullId:
      discard

  McpClientInfo* = object
    name*: string
    version*: string
    extraFields*: JsonNode

  McpClientCapabilities* = object
    ## Capability names are extensible, so their object is retained as JSON.
    fields*: JsonNode

  McpTraceContext* = object
    traceparent*: string
    tracestate*: string
    baggage*: string
    extensionFields*: JsonNode

  McpLogLevel* = enum
    mcpLogDebug
    mcpLogInfo
    mcpLogNotice
    mcpLogWarning
    mcpLogError
    mcpLogCritical
    mcpLogAlert
    mcpLogEmergency

  McpRequestMeta* = object
    protocolVersion*: string
    hasClientInfo*: bool
    clientInfo*: McpClientInfo
    clientCapabilities*: McpClientCapabilities
    hasTraceContext*: bool
    traceContext*: McpTraceContext
    hasLogLevel*: bool
    logLevel*: McpLogLevel
    hasProgressToken*: bool
    progressToken*: McpId
    extensionMetadata*: JsonNode

  McpParams* = object
    ## `values` contains method-specific params; `_meta` is decoded into `meta`.
    values*: JsonNode
    meta*: McpRequestMeta

  McpInputRequest* = object
    ## A server-to-client request embedded in an input_required result.
    methodName*: string
    params*: JsonNode
    extraFields*: JsonNode

  McpResultType* = enum
    mcpComplete
    mcpInputRequired

  McpResult* = object
    resultType*: McpResultType
    ## Result fields are method-specific and retained for forward compatibility.
    fields*: JsonNode

  McpRpcError* = object
    code*: int
    message*: string
    data*: JsonNode
    extraFields*: JsonNode

  McpRequestKind* = enum
    mcpRequest
    mcpNotification

  McpRpcRequest* = object
    case kind*: McpRequestKind
    of mcpRequest:
      id*: McpId
    of mcpNotification:
      discard
    methodName*: string
    params*: McpParams
    extraFields*: JsonNode

  McpRpcResponse* = object
    id*: McpId
    result*: McpResult
    extraFields*: JsonNode

  McpRpcErrorResponse* = object
    id*: McpId
    error*: McpRpcError
    extraFields*: JsonNode

  McpJsonRpcMessageKind* = enum
    mcpRequestMessage
    mcpNotificationMessage
    mcpResponseMessage
    mcpErrorMessage

  McpJsonRpcMessage* = object
    case kind*: McpJsonRpcMessageKind
    of mcpRequestMessage, mcpNotificationMessage:
      request*: McpRpcRequest
    of mcpResponseMessage:
      response*: McpRpcResponse
    of mcpErrorMessage:
      errorResponse*: McpRpcErrorResponse

  McpToolResult* = object
    ## Handler-facing result before it is wrapped in a JSON-RPC result.
    content*: JsonNode
    structuredContent*: JsonNode
    isError*: bool

proc newMcpError*(message: string, code = mcpInvalidParamsCode,
                  data: JsonNode = nil): ref McpError =
  result = newException(McpError, message)
  result.code = code
  result.data = data

proc invalidRequest(message: string): ref McpError =
  newMcpError(message, mcpInvalidRequestCode)

proc parseError(message: string): ref McpError =
  newMcpError(message, mcpParseErrorCode)

proc requireProtocolObject(node: JsonNode, context: string): JsonNode =
  if node.isNil or node.kind != JObject:
    raise invalidRequest(context & " must be an object")
  node

proc requireObject*(node: JsonNode, context: string): JsonNode =
  if node.isNil or node.kind != JObject:
    raise newMcpError(context & " must be an object")
  node

proc requiredString*(node: JsonNode, key, context: string): string =
  if node.isNil or node.kind != JObject or key notin node or
      node[key].kind != JString or node[key].getStr.len == 0:
    raise newMcpError(context & " requires a non-empty '" & key & "'")
  node[key].getStr

proc copyObject(node: JsonNode): JsonNode =
  result = newJObject()
  if node.isNil or node.kind != JObject: return
  for key, value in node.pairs:
    result[key] = value

proc withoutKey(node: JsonNode, excluded: string): JsonNode =
  result = newJObject()
  for key, value in node.pairs:
    if key != excluded:
      result[key] = value

proc parseMcpId*(node: JsonNode, allowNull = false): McpId =
  if node.isNil:
    raise invalidRequest("JSON-RPC id must be a string or integer")
  case node.kind
  of JString:
    McpId(kind: mcpStringId, stringValue: node.getStr)
  of JInt:
    McpId(kind: mcpIntegerId, integerValue: node.getInt.int64)
  of JNull:
    if not allowNull:
      raise invalidRequest("JSON-RPC id must not be null")
    McpId(kind: mcpNullId)
  else:
    raise invalidRequest("JSON-RPC id must be a string or integer")

proc toJson*(id: McpId): JsonNode =
  case id.kind
  of mcpStringId: newJString(id.stringValue)
  of mcpIntegerId: newJInt(id.integerValue)
  of mcpNullId: newJNull()

proc resultTypeName*(resultType: McpResultType): string =
  case resultType
  of mcpComplete: "complete"
  of mcpInputRequired: "input_required"

proc parseResultType(value: string): McpResultType =
  case value
  of "complete": mcpComplete
  of "input_required": mcpInputRequired
  else: raise invalidRequest("resultType must be complete or input_required")

proc inputRequestMethod(methodName: string): bool =
  methodName in ["elicitation/create", "sampling/createMessage", "roots/list"]

proc validateInputRequests(value: JsonNode) =
  if value.kind != JObject:
    raise invalidRequest("inputRequests must be an object")
  for key, request in value.pairs:
    if key.len == 0:
      raise invalidRequest("inputRequests keys must not be empty")
    if request.kind != JObject or "method" notin request or
        request["method"].kind != JString or
        not inputRequestMethod(request["method"].getStr):
      raise invalidRequest("inputRequests values must be supported request objects")
    if "params" in request and request["params"].kind != JObject:
      raise invalidRequest("input request params must be an object")

proc validateInputResponses(value: JsonNode) =
  if value.kind != JObject:
    raise invalidRequest("inputResponses must be an object")
  for key, response in value.pairs:
    if key.len == 0 or response.kind != JObject:
      raise invalidRequest("inputResponses values must be objects")
    if "action" in response and (response["action"].kind != JString or
        response["action"].getStr notin ["accept", "decline", "cancel"]):
      raise invalidRequest("input response action must be accept, decline, or cancel")

proc validateResultFields(resultType: McpResultType, fields: JsonNode) =
  if fields.isNil or fields.kind != JObject:
    raise invalidRequest("JSON-RPC result must be an object")
  if "_meta" in fields and fields["_meta"].kind != JObject:
    raise invalidRequest("result _meta must be an object")
  if "content" in fields and fields["content"].kind != JArray:
    raise invalidRequest("result content must be an array")
  if "isError" in fields and fields["isError"].kind != JBool:
    raise invalidRequest("result isError must be a boolean")
  if resultType == mcpInputRequired:
    if "inputRequests" in fields:
      validateInputRequests(fields["inputRequests"])
    if "requestState" in fields and (fields["requestState"].kind != JString or
        fields["requestState"].getStr.len == 0):
      raise invalidRequest("requestState must be a non-empty string")
    if "inputRequests" notin fields and "requestState" notin fields:
      raise invalidRequest("input_required result requires inputRequests or requestState")

proc newMcpResult*(resultType: McpResultType,
                   fields: JsonNode = nil): McpResult =
  result.resultType = resultType
  result.fields = if fields.isNil: newJObject() else: fields
  validateResultFields(resultType, result.fields)

proc parseMcpResult*(node: JsonNode): McpResult =
  let value = requireProtocolObject(node, "JSON-RPC result")
  if "resultType" notin value or value["resultType"].kind != JString:
    raise invalidRequest("JSON-RPC result requires a string resultType")
  result.resultType = parseResultType(value["resultType"].getStr)
  result.fields = withoutKey(value, "resultType")
  validateResultFields(result.resultType, result.fields)

proc toJson*(value: McpResult): JsonNode =
  result = copyObject(value.fields)
  result["resultType"] = %value.resultType.resultTypeName

proc newMcpRpcError*(code: int, message: string,
                     data: JsonNode = nil,
                     extraFields: JsonNode = nil): McpRpcError =
  if message.len == 0:
    raise newMcpError("JSON-RPC error message must not be empty")
  if not extraFields.isNil and extraFields.kind != JObject:
    raise newMcpError("JSON-RPC error extraFields must be an object")
  result = McpRpcError(code: code, message: message, data: data,
    extraFields: if extraFields.isNil: newJObject() else: extraFields)

proc parseMcpRpcError*(node: JsonNode): McpRpcError =
  let value = requireProtocolObject(node, "JSON-RPC error")
  if "code" notin value or value["code"].kind != JInt:
    raise invalidRequest("JSON-RPC error requires an integer code")
  if "message" notin value or value["message"].kind != JString or
      value["message"].getStr.len == 0:
    raise invalidRequest("JSON-RPC error requires a non-empty message")
  result.code = value["code"].getInt
  result.message = value["message"].getStr
  result.data = if "data" in value: value["data"] else: nil
  result.extraFields = newJObject()
  for key, item in value.pairs:
    if key notin ["code", "message", "data"]:
      result.extraFields[key] = item

proc toJson*(value: McpRpcError): JsonNode =
  result = copyObject(value.extraFields)
  result["code"] = %value.code
  result["message"] = %value.message
  if not value.data.isNil:
    result["data"] = value.data

proc logLevelName*(level: McpLogLevel): string =
  case level
  of mcpLogDebug: "debug"
  of mcpLogInfo: "info"
  of mcpLogNotice: "notice"
  of mcpLogWarning: "warning"
  of mcpLogError: "error"
  of mcpLogCritical: "critical"
  of mcpLogAlert: "alert"
  of mcpLogEmergency: "emergency"

proc parseLogLevel(value: string): McpLogLevel =
  case value
  of "debug": mcpLogDebug
  of "info": mcpLogInfo
  of "notice": mcpLogNotice
  of "warning": mcpLogWarning
  of "error": mcpLogError
  of "critical": mcpLogCritical
  of "alert": mcpLogAlert
  of "emergency": mcpLogEmergency
  else: raise newMcpError("unsupported log level: " & value)

proc parseMcpClientInfo(value: JsonNode): McpClientInfo =
  let info = requireObject(value, "request clientInfo")
  result.name = requiredString(info, "name", "request clientInfo")
  result.version = requiredString(info, "version", "request clientInfo")
  result.extraFields = newJObject()
  for key, item in info.pairs:
    if key notin ["name", "version"]:
      result.extraFields[key] = item

proc toJson*(value: McpClientInfo): JsonNode =
  result = copyObject(value.extraFields)
  result["name"] = %value.name
  result["version"] = %value.version

proc parseMcpClientCapabilities(value: JsonNode): McpClientCapabilities =
  result.fields = requireObject(value, "request clientCapabilities")

proc toJson*(value: McpClientCapabilities): JsonNode =
  copyObject(value.fields)

proc parseMcpTraceContext(value: JsonNode): McpTraceContext =
  let context = requireObject(value, "request traceContext")
  result.extensionFields = newJObject()
  for key, item in context.pairs:
    if key == "traceparent" or key == "tracestate" or key == "baggage":
      if item.kind != JString:
        raise newMcpError("request traceContext '" & key & "' must be a string")
      case key
      of "traceparent": result.traceparent = item.getStr
      of "tracestate": result.tracestate = item.getStr
      of "baggage": result.baggage = item.getStr
      else: discard
    else:
      result.extensionFields[key] = item

proc toJson*(value: McpTraceContext): JsonNode =
  result = copyObject(value.extensionFields)
  if value.traceparent.len > 0: result["traceparent"] = %value.traceparent
  if value.tracestate.len > 0: result["tracestate"] = %value.tracestate
  if value.baggage.len > 0: result["baggage"] = %value.baggage

proc parseMcpRequestMeta*(node: JsonNode): McpRequestMeta =
  let meta = requireObject(node, "request _meta")
  if mcpMetaProtocolVersionKey notin meta or
      meta[mcpMetaProtocolVersionKey].kind != JString:
    raise newMcpError("unsupported MCP protocol version: missing",
      mcpUnsupportedProtocolVersionCode,
      %*{"supportedVersions": [mcpProtocolVersion]})
  result.protocolVersion = meta[mcpMetaProtocolVersionKey].getStr
  if result.protocolVersion != mcpProtocolVersion:
    raise newMcpError("unsupported MCP protocol version: " & result.protocolVersion,
      mcpUnsupportedProtocolVersionCode,
      %*{"supportedVersions": [mcpProtocolVersion]})
  if mcpMetaClientCapabilitiesKey notin meta:
    raise newMcpError("request _meta requires clientCapabilities")
  result.clientCapabilities = parseMcpClientCapabilities(
    meta[mcpMetaClientCapabilitiesKey])
  if mcpMetaClientInfoKey in meta:
    result.hasClientInfo = true
    result.clientInfo = parseMcpClientInfo(meta[mcpMetaClientInfoKey])
  if mcpMetaTraceContextKey in meta:
    result.hasTraceContext = true
    result.traceContext = parseMcpTraceContext(meta[mcpMetaTraceContextKey])
  if mcpMetaLogLevelKey in meta:
    if meta[mcpMetaLogLevelKey].kind != JString:
      raise newMcpError("request logLevel must be a string")
    result.hasLogLevel = true
    result.logLevel = parseLogLevel(meta[mcpMetaLogLevelKey].getStr)
  if mcpMetaProgressTokenKey in meta:
    result.hasProgressToken = true
    result.progressToken = parseMcpId(meta[mcpMetaProgressTokenKey])
  result.extensionMetadata = newJObject()
  for key, value in meta.pairs:
    if key notin [mcpMetaProtocolVersionKey, mcpMetaClientInfoKey,
                 mcpMetaClientCapabilitiesKey, mcpMetaTraceContextKey,
                 mcpMetaLogLevelKey, mcpMetaProgressTokenKey]:
      result.extensionMetadata[key] = value

proc toJson*(value: McpRequestMeta): JsonNode =
  result = copyObject(value.extensionMetadata)
  result[mcpMetaProtocolVersionKey] = %value.protocolVersion
  result[mcpMetaClientCapabilitiesKey] = toJson(value.clientCapabilities)
  if value.hasClientInfo:
    result[mcpMetaClientInfoKey] = toJson(value.clientInfo)
  if value.hasTraceContext:
    result[mcpMetaTraceContextKey] = toJson(value.traceContext)
  if value.hasLogLevel:
    result[mcpMetaLogLevelKey] = %value.logLevel.logLevelName
  if value.hasProgressToken:
    result[mcpMetaProgressTokenKey] = toJson(value.progressToken)

proc parseMcpParams*(node: JsonNode): McpParams =
  let params = requireObject(node, "request params")
  if "_meta" notin params:
    raise newMcpError("request params require _meta")
  result.meta = parseMcpRequestMeta(params["_meta"])
  result.values = withoutKey(params, "_meta")
  if "inputResponses" in result.values:
    validateInputResponses(result.values["inputResponses"])
  if "requestState" in result.values and
      (result.values["requestState"].kind != JString or
       result.values["requestState"].getStr.len == 0):
    raise newMcpError("requestState must be a non-empty string")

proc toJson*(value: McpParams): JsonNode =
  result = copyObject(value.values)
  result["_meta"] = toJson(value.meta)

proc validateMethod*(methodName: string) =
  if methodName.len == 0:
    raise invalidRequest("JSON-RPC method must not be empty")
  if methodName.startsWith("rpc."):
    raise invalidRequest("JSON-RPC method names beginning with rpc. are reserved")

proc validateJsonRpcVersion(node: JsonNode) =
  if "jsonrpc" notin node or node["jsonrpc"].kind != JString or
      node["jsonrpc"].getStr != mcpJsonRpcVersion:
    raise invalidRequest("invalid JSON-RPC version")

proc checkNestingDepth(node: JsonNode, maxDepth: int)

proc parseMcpRequest*(node: JsonNode,
                      maxNestingDepth = mcpDefaultMaxNestingDepth): McpRpcRequest

proc parseMcpResponse*(node: JsonNode): McpRpcResponse =
  let value = requireProtocolObject(node, "JSON-RPC response")
  validateJsonRpcVersion(value)
  if "id" notin value:
    raise invalidRequest("JSON-RPC response requires an id")
  if "result" notin value or "error" in value:
    raise invalidRequest("JSON-RPC response requires exactly one result")
  let responseId = parseMcpId(value["id"])
  let responseResult = parseMcpResult(value["result"])
  var extraFields = newJObject()
  for key, item in value.pairs:
    if key notin ["jsonrpc", "id", "result"]:
      extraFields[key] = item
  McpRpcResponse(id: responseId, result: responseResult,
    extraFields: extraFields)

proc parseMcpErrorResponse*(node: JsonNode): McpRpcErrorResponse =
  let value = requireProtocolObject(node, "JSON-RPC error response")
  validateJsonRpcVersion(value)
  if "id" notin value:
    raise invalidRequest("JSON-RPC error response requires an id")
  if "error" notin value or "result" in value:
    raise invalidRequest("JSON-RPC error response requires exactly one error")
  let responseId = parseMcpId(value["id"], allowNull = true)
  let responseError = parseMcpRpcError(value["error"])
  var extraFields = newJObject()
  for key, item in value.pairs:
    if key notin ["jsonrpc", "id", "error"]:
      extraFields[key] = item
  McpRpcErrorResponse(id: responseId, error: responseError,
    extraFields: extraFields)

proc parseMcpRequest*(node: JsonNode,
                      maxNestingDepth = mcpDefaultMaxNestingDepth): McpRpcRequest =
  if node.isNil or node.kind != JObject:
    raise invalidRequest("invalid JSON-RPC request")
  checkNestingDepth(node, maxNestingDepth)
  validateJsonRpcVersion(node)
  if "method" notin node or node["method"].kind != JString:
    raise invalidRequest("JSON-RPC request requires a string method")
  validateMethod(node["method"].getStr)
  if "params" notin node:
    raise invalidRequest("JSON-RPC request requires params")
  if "result" in node or "error" in node:
    raise invalidRequest("JSON-RPC request cannot contain result or error")
  let requestId = if "id" in node: parseMcpId(node["id"]) else:
    McpId(kind: mcpNullId)
  let requestParams = parseMcpParams(node["params"])
  var extraFields = newJObject()
  for key, item in node.pairs:
    if key notin ["jsonrpc", "id", "method", "params"]:
      extraFields[key] = item
  result = if "id" in node:
    McpRpcRequest(kind: mcpRequest, id: requestId,
      methodName: node["method"].getStr, params: requestParams,
      extraFields: extraFields)
  else:
    McpRpcRequest(kind: mcpNotification,
      methodName: node["method"].getStr, params: requestParams,
      extraFields: extraFields)

proc parseMcpMessage*(node: JsonNode,
                      maxNestingDepth = mcpDefaultMaxNestingDepth): McpJsonRpcMessage =
  if node.isNil or node.kind != JObject:
    raise invalidRequest("invalid JSON-RPC message")
  checkNestingDepth(node, maxNestingDepth)
  if "method" in node:
    let request = parseMcpRequest(node, maxNestingDepth)
    result = if request.kind == mcpRequest:
      McpJsonRpcMessage(kind: mcpRequestMessage, request: request)
    else:
      McpJsonRpcMessage(kind: mcpNotificationMessage, request: request)
  elif "result" in node:
    result = McpJsonRpcMessage(kind: mcpResponseMessage,
      response: parseMcpResponse(node))
  elif "error" in node:
    result = McpJsonRpcMessage(kind: mcpErrorMessage,
      errorResponse: parseMcpErrorResponse(node))
  else:
    raise invalidRequest("invalid JSON-RPC message")

proc nestingDepth(node: JsonNode): int =
  if node.isNil: return 0
  case node.kind
  of JObject:
    for _, value in node.pairs:
      result = max(result, nestingDepth(value))
    inc result
  of JArray:
    for value in node.items:
      result = max(result, nestingDepth(value))
    inc result
  else: discard

proc checkNestingDepth(node: JsonNode, maxDepth: int) =
  if maxDepth < 1:
    raise parseError("maximum nesting depth must be positive")
  if nestingDepth(node) > maxDepth:
    raise parseError("JSON message exceeds maximum nesting depth")

proc scanNestingDepth(payload: string): int =
  var depth = 0
  var inString = false
  var escaped = false
  for character in payload:
    if inString:
      if escaped:
        escaped = false
      elif character == '\\':
        escaped = true
      elif character == '"':
        inString = false
    else:
      case character
      of '"': inString = true
      of '{', '[':
        inc depth
        result = max(result, depth)
      of '}', ']':
        if depth > 0: dec depth
      else: discard

proc parseMcpMessage*(payload: string,
                      maxMessageBytes = mcpDefaultMaxMessageBytes,
                      maxNestingDepth = mcpDefaultMaxNestingDepth): McpJsonRpcMessage =
  if maxMessageBytes < 1:
    raise parseError("maximum message size must be positive")
  if payload.len > maxMessageBytes:
    raise parseError("JSON message exceeds maximum size")
  if scanNestingDepth(payload) > maxNestingDepth:
    raise parseError("JSON message exceeds maximum nesting depth")
  var node: JsonNode
  try:
    node = parseJson(payload)
  except CatchableError as error:
    raise parseError("parse error: " & error.msg)
  parseMcpMessage(node, maxNestingDepth)

proc successResponse*(id: McpId, value: McpResult): McpJsonRpcMessage =
  McpJsonRpcMessage(kind: mcpResponseMessage,
    response: McpRpcResponse(id: id, result: value, extraFields: newJObject()))

proc errorResponse*(id: McpId, code: int, message: string,
                    data: JsonNode = nil): McpJsonRpcMessage =
  McpJsonRpcMessage(kind: mcpErrorMessage,
    errorResponse: McpRpcErrorResponse(
      id: id,
      error: newMcpRpcError(code, message, data),
      extraFields: newJObject()))

proc requestIdOrNull*(node: JsonNode): McpId =
  result = McpId(kind: mcpNullId)
  if node.isNil or node.kind != JObject or "id" notin node: return
  try:
    result = parseMcpId(node["id"], allowNull = true)
  except McpError:
    discard

proc toJson*(value: McpRpcRequest): JsonNode =
  result = copyObject(value.extraFields)
  result["jsonrpc"] = %mcpJsonRpcVersion
  if value.kind == mcpRequest:
    result["id"] = toJson(value.id)
  result["method"] = %value.methodName
  result["params"] = toJson(value.params)

proc toJson*(value: McpRpcResponse): JsonNode =
  result = copyObject(value.extraFields)
  result["jsonrpc"] = %mcpJsonRpcVersion
  result["id"] = toJson(value.id)
  result["result"] = toJson(value.result)

proc toJson*(value: McpRpcErrorResponse): JsonNode =
  result = copyObject(value.extraFields)
  result["jsonrpc"] = %mcpJsonRpcVersion
  result["id"] = toJson(value.id)
  result["error"] = toJson(value.error)

proc toJson*(value: McpJsonRpcMessage): JsonNode =
  case value.kind
  of mcpRequestMessage, mcpNotificationMessage:
    toJson(value.request)
  of mcpResponseMessage:
    toJson(value.response)
  of mcpErrorMessage:
    toJson(value.errorResponse)

proc textResult*(text: string, isError = false): McpToolResult =
  result.content = newJArray()
  result.content.add %*{"type": "text", "text": text}
  result.isError = isError

proc jsonResult*(value: JsonNode, isError = false): McpToolResult =
  result = textResult(if value.isNil: "null" else: $value, isError)
  result.structuredContent = if value.isNil: newJNull() else: value

proc addAnnotations(content, annotations: JsonNode): JsonNode =
  if not annotations.isNil:
    if annotations.kind != JObject:
      raise newMcpError("content annotations must be an object")
    content["annotations"] = annotations
  content

proc textContent*(text: string, annotations: JsonNode = nil): JsonNode =
  addAnnotations(%*{"type": "text", "text": text}, annotations)

proc imageContent*(data, mimeType: string,
                   annotations: JsonNode = nil): JsonNode =
  if mimeType.len == 0:
    raise newMcpError("image content requires a mimeType")
  addAnnotations(%*{"type": "image", "data": data, "mimeType": mimeType},
    annotations)

proc audioContent*(data, mimeType: string,
                   annotations: JsonNode = nil): JsonNode =
  if mimeType.len == 0:
    raise newMcpError("audio content requires a mimeType")
  addAnnotations(%*{"type": "audio", "data": data, "mimeType": mimeType},
    annotations)

proc resourceLinkContent*(uri, name: string, mimeType = "", title = "",
                          description = "", size: int64 = -1,
                          annotations: JsonNode = nil): JsonNode =
  if uri.len == 0 or name.len == 0:
    raise newMcpError("resource link requires a non-empty uri and name")
  if size < -1:
    raise newMcpError("resource link size must be non-negative")
  result = %*{"type": "resource_link", "uri": uri, "name": name}
  if mimeType.len > 0: result["mimeType"] = %mimeType
  if title.len > 0: result["title"] = %title
  if description.len > 0: result["description"] = %description
  if size >= 0: result["size"] = %size
  result = addAnnotations(result, annotations)

proc embeddedResourceContent*(resource: JsonNode,
                              annotations: JsonNode = nil): JsonNode =
  if resource.isNil or resource.kind != JObject:
    raise newMcpError("embedded resource must be an object")
  if "uri" notin resource or resource["uri"].kind != JString or
      resource["uri"].getStr.len == 0:
    raise newMcpError("embedded resource requires a non-empty uri")
  if "text" notin resource and "blob" notin resource:
    raise newMcpError("embedded resource requires text or blob content")
  if "text" in resource and "blob" in resource:
    raise newMcpError("embedded resource cannot contain both text and blob")
  addAnnotations(%*{"type": "resource", "resource": resource}, annotations)

proc newMcpToolResult*(content: JsonNode,
                       structuredContent: JsonNode = nil,
                       isError = false): McpToolResult =
  if content.isNil or content.kind != JArray:
    raise newMcpError("tool result content must be an array")
  McpToolResult(content: content, structuredContent: structuredContent,
    isError: isError)

proc structuredResult*(value: JsonNode, isError = false): McpToolResult =
  jsonResult(value, isError)
