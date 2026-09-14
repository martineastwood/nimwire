## Multi round-trip requests and low-level input handling.

import std/[json, tables]

import ./core
import ./schema
import ./security

type
  McpElicitationMode* = enum
    mcpElicitationForm
    mcpElicitationUrl

  McpElicitationRequest* = object
    mode*: McpElicitationMode
    message*: string
    requestedSchema*: JsonNode
    url*: string

  McpElicitationAction* = enum
    mcpElicitationAccept
    mcpElicitationDecline
    mcpElicitationCancel

  McpElicitationResult* = object
    action*: McpElicitationAction
    content*: JsonNode

  McpInputRequests* = Table[string, McpInputRequest]
  McpElicitationHandler* = proc (request: McpElicitationRequest):
      McpElicitationResult {.closure.}
  McpInputResponseHandler* = proc (request: McpInputRequest):
      JsonNode {.closure.}

  McpInputClient* = ref object
    elicitationHandler*: McpElicitationHandler
    samplingHandler*: McpInputResponseHandler
    rootsHandler*: McpInputResponseHandler
    nextRequestId: int64
    usedRequestIds: seq[McpId]

proc inputMethodName(methodName: string): bool =
  methodName in ["elicitation/create", "sampling/createMessage", "roots/list"]

proc inputActionName(action: McpElicitationAction): string =
  case action
  of mcpElicitationAccept: "accept"
  of mcpElicitationDecline: "decline"
  of mcpElicitationCancel: "cancel"

proc parseInputAction(value: string): McpElicitationAction =
  case value
  of "accept": mcpElicitationAccept
  of "decline": mcpElicitationDecline
  of "cancel": mcpElicitationCancel
  else: raise newMcpError("elicitation action must be accept, decline, or cancel")

proc newMcpInputRequest*(methodName: string,
                         params: JsonNode = nil): McpInputRequest =
  if not inputMethodName(methodName):
    raise newMcpError("unsupported input request method: " & methodName)
  result = McpInputRequest(methodName: methodName,
    params: if params.isNil: newJObject() else: params,
    extraFields: newJObject())
  if result.params.kind != JObject:
    raise newMcpError("input request params must be an object")

proc newMcpElicitationFormRequest*(message: string,
                                   requestedSchema: JsonNode): McpInputRequest =
  if message.len == 0:
    raise newMcpError("elicitation message must not be empty")
  discard requireJsonSchema(requestedSchema, "elicitation requestedSchema")
  if "type" notin requestedSchema or
      requestedSchema["type"].kind != JString or
      requestedSchema["type"].getStr != "object":
    raise newMcpError("elicitation requestedSchema must describe an object")
  newMcpInputRequest("elicitation/create", %*{
    "mode": "form", "message": message, "requestedSchema": requestedSchema
  })

proc newMcpElicitationUrlRequest*(message, url: string): McpInputRequest =
  if message.len == 0:
    raise newMcpError("elicitation message must not be empty")
  discard requireSafeMcpUrl(url)
  newMcpInputRequest("elicitation/create", %*{
    "mode": "url", "message": message, "url": url
  })

proc toJson*(value: McpInputRequest): JsonNode =
  result = newJObject()
  for key, item in value.extraFields.pairs:
    result[key] = item
  result["method"] = %value.methodName
  if not value.params.isNil: result["params"] = value.params

proc parseMcpInputRequest*(node: JsonNode): McpInputRequest =
  if node.isNil or node.kind != JObject or "method" notin node or
      node["method"].kind != JString:
    raise newMcpError("input request requires a method")
  let params = if "params" in node: node["params"] else: newJObject()
  result = newMcpInputRequest(node["method"].getStr, params)
  for key, item in node.pairs:
    if key notin ["method", "params"]:
      result.extraFields[key] = item

proc inputRequestsJson*(inputRequests: McpInputRequests): JsonNode =
  result = newJObject()
  for key, request in inputRequests.pairs:
    if key.len == 0:
      raise newMcpError("input request keys must not be empty")
    result[key] = toJson(request)

proc newMcpInputRequiredResult*(inputRequests: JsonNode = nil,
                               requestState = ""): McpWireResult =
  var fields = newJObject()
  if not inputRequests.isNil:
    if inputRequests.kind != JObject:
      raise newMcpError("inputRequests must be an object")
    fields["inputRequests"] = inputRequests
  if requestState.len > 0:
    fields["requestState"] = %requestState
  newMcpResult(mcpInputRequired, fields)

proc newMcpInputRequiredResult*(inputRequests: McpInputRequests,
                               requestState = ""): McpWireResult =
  newMcpInputRequiredResult(inputRequests.inputRequestsJson, requestState)

proc newMcpInputRequiredResult*(entries: openArray[(string, McpInputRequest)],
                               requestState = ""): McpWireResult =
  var inputRequests = initTable[string, McpInputRequest]()
  for entry in entries:
    if entry[0].len == 0 or entry[0] in inputRequests:
      raise newMcpError("input request keys must be unique and non-empty")
    inputRequests[entry[0]] = entry[1]
  newMcpInputRequiredResult(inputRequests, requestState)

proc parseInputRequests*(value: McpWireResult): McpInputRequests =
  if value.resultType != mcpInputRequired:
    raise newMcpError("result is not input_required")
  var output = initTable[string, McpInputRequest]()
  if "inputRequests" notin value.fields:
    return output
  for key, item in value.fields["inputRequests"].pairs:
    output[key] = parseMcpInputRequest(item)
  output

proc parseMcpElicitationRequest*(request: McpInputRequest):
    McpElicitationRequest =
  if request.methodName != "elicitation/create":
    raise newMcpError("input request is not elicitation/create")
  let params = request.params
  let message = requiredString(params, "message", "elicitation/create")
  let mode = if "mode" notin params: "form" else:
    if params["mode"].kind != JString:
      raise newMcpError("elicitation mode must be a string")
    params["mode"].getStr
  case mode
  of "form":
    if "requestedSchema" notin params:
      raise newMcpError("form elicitation requires requestedSchema")
    discard requireJsonSchema(params["requestedSchema"],
      "elicitation requestedSchema")
    if params["requestedSchema"].kind != JObject:
      raise newMcpError("elicitation requestedSchema must be an object")
    McpElicitationRequest(mode: mcpElicitationForm, message: message,
      requestedSchema: params["requestedSchema"])
  of "url":
    let url = requiredString(params, "url", "elicitation/create")
    discard requireSafeMcpUrl(url)
    McpElicitationRequest(mode: mcpElicitationUrl, message: message, url: url)
  else:
    raise newMcpError("elicitation mode must be form or url")

proc newMcpElicitationResult*(action: McpElicitationAction,
                              content: JsonNode = nil): McpElicitationResult =
  if action != mcpElicitationAccept and not content.isNil:
    raise newMcpError("declined or cancelled elicitation must not include content")
  McpElicitationResult(action: action, content: content)

proc acceptElicitation*(content: JsonNode = nil): McpElicitationResult =
  newMcpElicitationResult(mcpElicitationAccept, content)

proc declineElicitation*(): McpElicitationResult =
  newMcpElicitationResult(mcpElicitationDecline)

proc cancelElicitation*(): McpElicitationResult =
  newMcpElicitationResult(mcpElicitationCancel)

proc toJson*(value: McpElicitationResult): JsonNode =
  result = %*{"action": value.action.inputActionName}
  if not value.content.isNil: result["content"] = value.content

proc parseMcpElicitationResult*(node: JsonNode): McpElicitationResult =
  let value = requireObject(node, "elicitation response")
  let action = requiredString(value, "action", "elicitation response")
  result.action = parseInputAction(action)
  if "content" in value: result.content = value["content"]

proc validateElicitationResponse*(request: McpElicitationRequest,
                                 response: McpElicitationResult) =
  if response.action != mcpElicitationAccept: return
  case request.mode
  of mcpElicitationForm:
    if response.content.isNil or response.content.kind != JObject:
      raise newMcpError("accepted form elicitation requires object content")
    validateJsonValue(request.requestedSchema, response.content,
      "elicitation response content")
  of mcpElicitationUrl:
    if not response.content.isNil:
      raise newMcpError("accepted URL elicitation must not include content")

proc newMcpInputClient*(firstRequestId = 1'i64,
                        elicitationHandler: McpElicitationHandler = nil,
                        samplingHandler: McpInputResponseHandler = nil,
                        rootsHandler: McpInputResponseHandler = nil): McpInputClient =
  if firstRequestId < 0:
    raise newMcpError("first request id must not be negative")
  McpInputClient(nextRequestId: firstRequestId,
    elicitationHandler: elicitationHandler, samplingHandler: samplingHandler,
    rootsHandler: rootsHandler)

proc setElicitationHandler*(client: McpInputClient,
                            handler: McpElicitationHandler) =
  client.elicitationHandler = handler

proc setSamplingHandler*(client: McpInputClient,
                         handler: McpInputResponseHandler) =
  client.samplingHandler = handler

proc setRootsHandler*(client: McpInputClient,
                      handler: McpInputResponseHandler) =
  client.rootsHandler = handler

proc rememberRequest*(client: McpInputClient, id: McpId) =
  if client.isNil: raise newMcpError("input client must not be nil")
  if id.kind == mcpNullId:
    raise newMcpError("request id must not be null")
  for existing in client.usedRequestIds:
    if existing == id:
      raise newMcpError("request id has already been used")
  client.usedRequestIds.add id

proc hasRequestId(client: McpInputClient, id: McpId): bool =
  for existing in client.usedRequestIds:
    if existing == id: return true
  false

proc freshRequestId*(client: McpInputClient): McpId =
  if client.isNil: raise newMcpError("input client must not be nil")
  while true:
    let candidate = McpId(kind: mcpIntegerId, integerValue: client.nextRequestId)
    inc client.nextRequestId
    if not client.hasRequestId(candidate):
      return candidate

proc inputResponse(client: McpInputClient,
                   request: McpInputRequest): JsonNode =
  case request.methodName
  of "elicitation/create":
    if client.elicitationHandler.isNil:
      raise newMcpError("elicitation handler is not configured")
    let typedRequest = parseMcpElicitationRequest(request)
    let response = client.elicitationHandler(typedRequest)
    validateElicitationResponse(typedRequest, response)
    toJson(response)
  of "sampling/createMessage":
    if client.samplingHandler.isNil:
      raise newMcpError("sampling handler is not configured")
    let response = client.samplingHandler(request)
    if response.isNil or response.kind != JObject:
      raise newMcpError("sampling handler must return an object")
    response
  of "roots/list":
    if client.rootsHandler.isNil:
      raise newMcpError("roots handler is not configured")
    let response = client.rootsHandler(request)
    if response.isNil or response.kind != JObject:
      raise newMcpError("roots handler must return an object")
    response
  else:
    raise newMcpError("unsupported input request method: " & request.methodName)

proc retryInputRequired*(client: McpInputClient,
                         original, response: McpJsonRpcMessage,
                         retryId: McpId): McpJsonRpcMessage =
  if original.kind != mcpRequestMessage or response.kind != mcpResponseMessage:
    raise newMcpError("MRTR retry requires a request and result response")
  if original.request.id != response.response.id:
    raise newMcpError("MRTR response id does not match the request")
  if response.response.result.resultType != mcpInputRequired:
    raise newMcpError("MRTR retry requires an input_required result")
  if original.request.methodName notin ["tools/call", "prompts/get", "resources/read"]:
    raise newMcpError("method does not support MRTR retries")
  if client.hasRequestId(retryId):
    raise newMcpError("retry request id must be fresh")
  if not client.hasRequestId(original.request.id):
    client.rememberRequest(original.request.id)
  client.rememberRequest(retryId)

  var values = newJObject()
  for key, value in original.request.params.values.pairs:
    values[key] = value
  var responses = newJObject()
  if "inputResponses" in values:
    for key, value in values["inputResponses"].pairs:
      responses[key] = value
  for key, request in response.response.result.parseInputRequests.pairs:
    responses[key] = client.inputResponse(request)
  if responses.len > 0: values["inputResponses"] = responses
  if "requestState" in response.response.result.fields:
    values["requestState"] = response.response.result.fields["requestState"]
  else:
    values.delete("requestState")

  var params = original.request.params
  params.values = values
  McpJsonRpcMessage(kind: mcpRequestMessage,
    request: McpRpcRequest(kind: mcpRequest, id: retryId,
      methodName: original.request.methodName, params: params,
      extraFields: original.request.extraFields))

proc retryInputRequired*(client: McpInputClient,
                         original, response: McpJsonRpcMessage): McpJsonRpcMessage =
  if client.isNil: raise newMcpError("input client must not be nil")
  if original.kind != mcpRequestMessage:
    raise newMcpError("MRTR retry requires a request")
  if not client.hasRequestId(original.request.id):
    client.rememberRequest(original.request.id)
  client.retryInputRequired(original, response, client.freshRequestId())
