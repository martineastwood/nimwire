## Stateless Streamable HTTP transport.

import std/[asynchttpserver, asyncdispatch, base64, json, nativesockets,
            options, strutils, unicode, uri]

import ../core
import ../schema
import ../server

type
  McpHttpHeader* = object
    name*: string
    value*: string

  McpHttpRequest* = object
    ## Framework-neutral HTTP request passed to `handleHttpRequest`.
    httpMethod*: string
    path*: string
    headers*: seq[McpHttpHeader]
    body*: string

  McpHttpResponse* = object
    status*: int
    headers*: seq[McpHttpHeader]
    body*: string

  McpHttpConfig* = object
    endpoint*: string
    host*: string
    port*: Port
    maxBodyBytes*: int
    maxNestingDepth*: int
    requestTimeoutMs*: int
    maxConcurrentRequests*: int
    allowedHosts*: seq[string]
    allowedOrigins*: seq[string]
    preferSse*: bool

  McpHttpServer* = ref object
    app: McpServer
    transport: AsyncHttpServer
    config: McpHttpConfig
    started: bool
    stopping: bool
    activeRequests: int

proc newMcpHttpConfig*(endpoint = "/mcp", host = "127.0.0.1",
                       port = Port(0),
                       maxBodyBytes = mcpDefaultMaxMessageBytes,
                       maxNestingDepth = mcpDefaultMaxNestingDepth,
                       requestTimeoutMs = 0, maxConcurrentRequests = 0,
                       allowedHosts: seq[string] = @[],
                       allowedOrigins: seq[string] = @[],
                       preferSse = false): McpHttpConfig =
  if endpoint.len == 0 or not endpoint.startsWith("/"):
    raise newMcpError("HTTP endpoint must start with '/'")
  if maxBodyBytes < 1:
    raise newMcpError("HTTP maxBodyBytes must be positive")
  if maxNestingDepth < 1:
    raise newMcpError("HTTP maxNestingDepth must be positive")
  if requestTimeoutMs < 0:
    raise newMcpError("HTTP requestTimeoutMs must be at least 0")
  if maxConcurrentRequests < 0:
    raise newMcpError("HTTP maxConcurrentRequests must be at least 0")
  McpHttpConfig(endpoint: endpoint, host: host, port: port,
    maxBodyBytes: maxBodyBytes, maxNestingDepth: maxNestingDepth,
    requestTimeoutMs: requestTimeoutMs,
    maxConcurrentRequests: maxConcurrentRequests,
    allowedHosts: allowedHosts, allowedOrigins: allowedOrigins,
    preferSse: preferSse)

proc newMcpHttpRequest*(httpMethod, path: string, body = "",
                        headers: seq[McpHttpHeader] = @[]): McpHttpRequest =
  McpHttpRequest(httpMethod: httpMethod, path: path, headers: headers,
    body: body)

proc header*(name, value: string): McpHttpHeader =
  McpHttpHeader(name: name, value: value)

proc headerValues(headers: openArray[McpHttpHeader], name: string): seq[string] =
  for item in headers:
    if item.name.toLowerAscii == name.toLowerAscii:
      result.add item.value

proc headerValue(headers: openArray[McpHttpHeader], name: string): string =
  headerValues(headers, name).join(",")

proc hasHeader(headers: openArray[McpHttpHeader], name: string): bool =
  headerValues(headers, name).len > 0

proc addHeader(headers: var seq[McpHttpHeader], name, value: string) =
  headers.add McpHttpHeader(name: name, value: value)

proc plainResponse(status: int, body: string): McpHttpResponse =
  McpHttpResponse(status: status,
    headers: @[McpHttpHeader(name: "Content-Type",
      value: "text/plain; charset=utf-8")], body: body)

proc jsonResponse(status: int, body: string): McpHttpResponse =
  McpHttpResponse(status: status,
    headers: @[McpHttpHeader(name: "Content-Type",
      value: "application/json; charset=utf-8")], body: body)

proc jsonError(id: McpId, status, code: int, message: string,
               data: JsonNode = nil): McpHttpResponse =
  jsonResponse(status, $toJson(errorResponse(id, code, message, data)))

proc addCors(response: var McpHttpResponse, request: McpHttpRequest,
             config: McpHttpConfig, originAllowed: bool) =
  let origin = headerValue(request.headers, "Origin")
  if origin.len > 0 and originAllowed:
    response.headers.addHeader("Access-Control-Allow-Origin", origin)
    response.headers.addHeader("Access-Control-Allow-Headers",
      "Content-Type, MCP-Protocol-Version, Mcp-Method, Mcp-Name, Mcp-Param-*")
    response.headers.addHeader("Access-Control-Allow-Methods", "POST, OPTIONS")
    response.headers.addHeader("Vary", "Origin")

proc isHttpTokenCharacter(character: char): bool =
  (character >= 'a' and character <= 'z') or
    (character >= 'A' and character <= 'Z') or
    (character >= '0' and character <= '9') or
    character in {'!', '#', '$', '%', '&', '\'', '*', '+', '-', '.', '^',
                  '_', '`', '|', '~'}

proc validHeaderName(name: string): bool =
  if name.len == 0: return false
  for character in name:
    if not isHttpTokenCharacter(character): return false
  true

proc validHeaderEnvelope(request: McpHttpRequest): bool =
  for item in request.headers:
    if not validHeaderName(item.name): return false
    if '\r' in item.value or '\n' in item.value: return false
  true

proc hostWithoutPort(value: string): string =
  result = value.strip.toLowerAscii
  if result.startsWith("["):
    let close = result.find(']')
    if close >= 0: return result[1 ..< close]
  let colon = result.rfind(':')
  if colon > 0:
    var numericPort = true
    for character in result[colon + 1 .. ^1]:
      if character < '0' or character > '9': numericPort = false
    if numericPort: result.setLen(colon)

proc allowedHost(config: McpHttpConfig, request: McpHttpRequest): bool =
  if config.allowedHosts.len == 0: return true
  let values = headerValues(request.headers, "Host")
  if values.len != 1: return false
  let host = values[0].strip.toLowerAscii
  let hostname = hostWithoutPort(host)
  for allowed in config.allowedHosts:
    let value = allowed.strip.toLowerAscii
    if host == value: return true
    if value == hostWithoutPort(value) and hostname == value: return true
  false

proc allowedOrigin(config: McpHttpConfig, request: McpHttpRequest): bool =
  let values = headerValues(request.headers, "Origin")
  if values.len == 0: return true
  if values.len != 1: return false
  for allowed in config.allowedOrigins:
    if allowed == "*" or allowed == values[0]: return true
  false

proc endpointPath(path: string): string =
  let query = path.find('?')
  if query < 0: path else: path[0 ..< query]

proc accepts(headers: openArray[McpHttpHeader], mediaType: string): bool =
  for value in headerValues(headers, "Accept"):
    for item in value.split(','):
      let candidate = item.split(';', 1)[0].strip.toLowerAscii
      if candidate == mediaType: return true
  false

proc isJsonContentType(headers: openArray[McpHttpHeader]): bool =
  let values = headerValues(headers, "Content-Type")
  values.len == 1 and values[0].split(';', 1)[0].strip.toLowerAscii ==
    "application/json"

proc safePlainHeaderValue(value: string): bool =
  if value.len > 0 and (value[0] in {' ', '\t'} or
      value[^1] in {' ', '\t'}): return false
  for character in value:
    let code = character.uint8.int
    if code != 9 and (code < 32 or code > 126): return false
  true

proc encodedHeaderValue(value: string): bool =
  value.startsWith("=?base64?") and value.endsWith("?=")

proc decodeHeaderValue(value, headerName: string): string =
  if not encodedHeaderValue(value):
    if not safePlainHeaderValue(value):
      raise newMcpError("Header mismatch: invalid " & headerName &
        " header value", mcpHeaderMismatchCode)
    return value
  let start = "=?base64?".len
  let encoded = value[start ..< value.len - 2]
  try:
    result = decode(encoded)
  except CatchableError:
    raise newMcpError("Header mismatch: invalid " & headerName &
      " base64 value", mcpHeaderMismatchCode)
  if validateUtf8(result) >= 0:
    raise newMcpError("Header mismatch: " & headerName &
      " base64 value is not UTF-8", mcpHeaderMismatchCode)

proc encodeMcpHeaderValue*(value: string): string =
  ## Encode a UTF-8 value for `Mcp-Name` or `Mcp-Param-*`.
  if validateUtf8(value) >= 0:
    raise newMcpError("MCP header values must be valid UTF-8")
  if safePlainHeaderValue(value) and not encodedHeaderValue(value): return value
  "=?base64?" & encode(value) & "?="

proc mcpParamHeaderName*(name: string): string = "Mcp-Param-" & name

proc headerMismatch(message: string): ref McpError =
  newMcpError("Header mismatch: " & message, mcpHeaderMismatchCode)

proc valueAtPath(value: JsonNode, path: seq[string]): JsonNode =
  result = value
  for name in path:
    if result.isNil or result.kind != JObject or name notin result:
      return nil
    result = result[name]

proc expectedHeaderValue(value: JsonNode, valueType, headerName: string): string =
  if value.isNil or value.kind == JNull: return ""
  case valueType
  of "string":
    if value.kind != JString:
      raise headerMismatch(headerName & " does not match its body value")
    result = value.getStr
  of "integer":
    if value.kind != JInt or abs(value.getInt.int64) > 9007199254740991'i64:
      raise headerMismatch(headerName & " requires a safe integer body value")
    result = $value.getInt
  of "boolean":
    if value.kind != JBool:
      raise headerMismatch(headerName & " does not match its body value")
    result = if value.getBool: "true" else: "false"
  else:
    raise headerMismatch(headerName & " has an unsupported schema type")

proc compareHeader(headers: openArray[McpHttpHeader], name, expected: string) =
  let values = headerValues(headers, name)
  if values.len != 1:
    raise headerMismatch("missing or duplicate " & name & " header")
  if decodeHeaderValue(values[0], name) != expected:
    raise headerMismatch(name & " does not match the request body")

proc validateRequestHeaders(server: McpServer, request: McpRpcRequest,
                            headers: openArray[McpHttpHeader]) =
  let protocol = headerValues(headers, "MCP-Protocol-Version")
  if protocol.len != 1 or protocol[0] != request.params.meta.protocolVersion:
    raise headerMismatch("MCP-Protocol-Version does not match the request body")

  let methodHeader = headerValues(headers, "Mcp-Method")
  if methodHeader.len != 1 or methodHeader[0] != request.methodName:
    raise headerMismatch("Mcp-Method does not match the request body")

  var name = ""
  case request.methodName
  of "tools/call":
    if "name" in request.params.values and
        request.params.values["name"].kind == JString:
      name = request.params.values["name"].getStr
  of "resources/read":
    if "uri" in request.params.values and
        request.params.values["uri"].kind == JString:
      name = request.params.values["uri"].getStr
  of "prompts/get":
    if "name" in request.params.values and
        request.params.values["name"].kind == JString:
      name = request.params.values["name"].getStr
  else: discard
  if request.methodName in ["tools/call", "resources/read", "prompts/get"]:
    compareHeader(headers, "Mcp-Name", name)

  if request.methodName != "tools/call": return
  if "name" notin request.params.values or
      request.params.values["name"].kind != JString: return
  let toolIndex = server.findTool(request.params.values["name"].getStr)
  if toolIndex < 0: return
  let bindings = mcpHeaderBindings(server.tools[toolIndex].inputSchema)
  let arguments = if "arguments" in request.params.values and
      request.params.values["arguments"].kind == JObject:
    request.params.values["arguments"]
  else:
    newJObject()
  for binding in bindings:
    let headerName = mcpParamHeaderName(binding.name)
    let value = valueAtPath(arguments, binding.path)
    if value.isNil or value.kind == JNull:
      if hasHeader(headers, headerName):
        raise headerMismatch(headerName & " must be omitted for a null or missing body value")
    else:
      compareHeader(headers, headerName,
        expectedHeaderValue(value, binding.valueType, headerName))

proc addSseMessage(response: McpHttpResponse, value: JsonNode): McpHttpResponse =
  result = response
  result.headers = @[
    McpHttpHeader(name: "Content-Type", value: "text/event-stream; charset=utf-8"),
    McpHttpHeader(name: "Cache-Control", value: "no-cache"),
    McpHttpHeader(name: "X-Accel-Buffering", value: "no")]
  result.body = "event: message\r\ndata: " & $value & "\r\n\r\n"

proc withCors(response: McpHttpResponse, request: McpHttpRequest,
              config: McpHttpConfig, originAllowed: bool): McpHttpResponse =
  result = response
  result.addCors(request, config, originAllowed)

proc handleHttpRequest*(server: McpServer, request: McpHttpRequest,
                        config = newMcpHttpConfig()): Future[McpHttpResponse] {.async.} =
  let originOkay = allowedOrigin(config, request)
  if not validHeaderEnvelope(request):
    return withCors(plainResponse(400, "Invalid HTTP headers"), request, config,
      originOkay)
  if not allowedHost(config, request):
    return withCors(plainResponse(403, "Forbidden host"), request, config, false)
  if not originOkay:
    return withCors(plainResponse(403, "Forbidden origin"), request, config, false)
  if endpointPath(request.path) != config.endpoint:
    return withCors(plainResponse(404, "Not Found"), request, config, true)

  if request.httpMethod.toUpperAscii == "OPTIONS":
    return withCors(McpHttpResponse(status: 204), request, config, true)
  if request.httpMethod.toUpperAscii != "POST":
    var response = plainResponse(405, "Method Not Allowed")
    response.headers.addHeader("Allow", "POST, OPTIONS")
    return withCors(response, request, config, true)
  if request.body.len > config.maxBodyBytes:
    return withCors(jsonError(McpId(kind: mcpNullId), 413, mcpParseErrorCode,
      "JSON message exceeds maximum size"), request, config, true)
  if validateUtf8(request.body) >= 0:
    return withCors(jsonError(McpId(kind: mcpNullId), 400, mcpParseErrorCode,
      "JSON message must be UTF-8"), request, config, true)
  if not isJsonContentType(request.headers):
    return withCors(plainResponse(415, "Content-Type must be application/json"),
      request, config, true)
  if not accepts(request.headers, "application/json") or
      not accepts(request.headers, "text/event-stream"):
    return withCors(plainResponse(406,
      "Accept must include application/json and text/event-stream"), request,
      config, true)

  var message: McpJsonRpcMessage
  try:
    message = parseMcpMessage(request.body,
      maxMessageBytes = config.maxBodyBytes,
      maxNestingDepth = config.maxNestingDepth)
  except McpError as error:
    return withCors(jsonError(McpId(kind: mcpNullId), 400, error.code,
      error.msg, error.data), request, config, true)

  if message.kind notin {mcpRequestMessage, mcpNotificationMessage}:
    return withCors(jsonError(McpId(kind: mcpNullId), 400,
      mcpInvalidRequestCode, "Streamable HTTP accepts requests and notifications only"),
      request, config, true)

  let rpcRequest = message.request
  let requestId = if rpcRequest.kind == mcpRequest:
    rpcRequest.id
  else:
    McpId(kind: mcpNullId)
  try:
    validateRequestHeaders(server, rpcRequest, request.headers)
  except McpError as error:
    return withCors(jsonError(requestId, 400, error.code, error.msg, error.data),
      request, config, true)

  let dispatch = server.handleMessageAsync(message)
  if config.requestTimeoutMs > 0 and
      not await withTimeout(dispatch, config.requestTimeoutMs):
    return withCors(jsonError(requestId, 408, mcpInternalErrorCode,
      "MCP request timed out"), request, config, true)
  let output = await dispatch
  if output.isNone:
    return withCors(McpHttpResponse(status: 202), request, config, true)
  let value = toJson(output.get)
  let status = if output.get.kind == mcpErrorMessage and
      output.get.errorResponse.error.code == mcpMethodNotFoundCode: 404 else: 200
  var response = jsonResponse(status, $value)
  if config.preferSse:
    response = response.addSseMessage(value)
  withCors(response, request, config, true)

proc toMcpHttpRequest*(request: asynchttpserver.Request): McpHttpRequest =
  result.httpMethod = $request.reqMethod
  result.path = request.url.path
  result.body = request.body
  for name, value in request.headers.pairs:
    result.headers.add McpHttpHeader(name: name, value: value)

proc toHttpHeaders(headers: seq[McpHttpHeader]): HttpHeaders =
  result = newHttpHeaders()
  for item in headers:
    result.add(item.name, item.value)

proc newMcpHttpServer*(server: McpServer,
                       config = newMcpHttpConfig()): McpHttpServer =
  if server.isNil: raise newMcpError("MCP server must not be nil")
  result = McpHttpServer(app: server,
    transport: newAsyncHttpServer(maxBody = config.maxBodyBytes), config: config)

proc getPort*(server: McpHttpServer): Port =
  if server.isNil or not server.started:
    raise newMcpError("HTTP server is not listening")
  server.transport.getPort

proc handleStdlibRequest(server: McpHttpServer,
                         request: asynchttpserver.Request): Future[void] {.async.} =
  if server.stopping:
    await request.respond(Http503, "Server is shutting down")
    return
  if server.config.maxConcurrentRequests > 0 and
      server.activeRequests >= server.config.maxConcurrentRequests:
    await request.respond(Http429, "Too Many Requests")
    return
  inc server.activeRequests
  try:
    let response = await handleHttpRequest(server.app,
      toMcpHttpRequest(request), server.config)
    await request.respond(HttpCode(response.status), response.body,
      toHttpHeaders(response.headers))
  except CatchableError:
    try:
      await request.respond(Http500, "Internal Server Error")
    except CatchableError:
      discard
  finally:
    dec server.activeRequests

proc serveHttp*(server: McpHttpServer): Future[void] {.async.} =
  if server.isNil: raise newMcpError("HTTP server must not be nil")
  if server.started: raise newMcpError("HTTP server is already listening")
  server.transport.listen(server.config.port, server.config.host)
  server.started = true
  let callback = cast[proc (request: asynchttpserver.Request): Future[void]
      {.closure, gcsafe.}](proc (request: asynchttpserver.Request): Future[void] {.closure.} =
    server.handleStdlibRequest(request))
  try:
    while not server.stopping:
      try:
        await server.transport.acceptRequest(callback)
      except CatchableError:
        if not server.stopping: raise
  finally:
    if not server.stopping:
      server.stopping = true
      server.transport.close()
  while server.activeRequests > 0:
    await sleepAsync(10)

proc shutdown*(server: McpHttpServer) =
  if server.isNil: return
  server.stopping = true
  if server.started:
    server.transport.close()
