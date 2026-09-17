## WebSocket transport for persistent MCP connections.

import std/[asyncdispatch, asyncnet, base64, json, nativesockets, options,
            strutils, unicode]
import pkg/nimcrypto/sha

import ../auth
import ../context
import ../core
import ../server
import ../subscriptions

const
  wsDefaultMaxHeaderBytes* = 16 * 1024

type
  McpWebSocketError* = object of CatchableError

  McpWebSocketConfig* = object
    endpoint*: string
    host*: string
    port*: Port
    maxMessageBytes*: int
    maxHeaderBytes*: int
    maxNestingDepth*: int
    handshakeTimeoutMs*: int
    requestTimeoutMs*: int
    allowedHosts*: seq[string]
    allowedOrigins*: seq[string]
    authorization*: McpAuthorizationConfig

  McpWebSocketConnection = ref object
    server: McpWebSocketServer
    socket: AsyncSocket
    path: string
    remoteAddress: string
    principal: McpPrincipal
    writeTail: Future[void]
    contexts: seq[McpContext]
    subscriptions: seq[McpSubscription]
    closed: bool
    closeSent: bool

  McpWebSocketServer* = ref object
    app: McpServer
    transport: AsyncSocket
    config: McpWebSocketConfig
    started: bool
    stopping: bool
    activeConnections: int
    connections: seq[McpWebSocketConnection]

  WsHeader = object
    name: string
    value: string

  WsFrame = object
    fin: bool
    opcode: int
    payload: string

  WsMessage = object
    closed: bool
    payload: string

  WsPeerClosed = object of McpWebSocketError
  WsProtocolFault = object of McpWebSocketError
    code: uint16

proc protocolFault(code: uint16, message: string): ref WsProtocolFault =
  result = newException(WsProtocolFault, message)
  result.code = code

proc newMcpWebSocketConfig*(endpoint = "/mcp", host = "127.0.0.1",
                            port = Port(0),
                            maxMessageBytes = mcpDefaultMaxMessageBytes,
                            maxHeaderBytes = wsDefaultMaxHeaderBytes,
                            maxNestingDepth = mcpDefaultMaxNestingDepth,
                            handshakeTimeoutMs = 10_000,
                            requestTimeoutMs = 0,
                            allowedHosts: seq[string] = @[],
                            allowedOrigins: seq[string] = @[],
                            authorization = McpAuthorizationConfig()):
                            McpWebSocketConfig =
  if endpoint.len == 0 or not endpoint.startsWith("/"):
    raise newMcpError("WebSocket endpoint must start with '/'")
  if maxMessageBytes < 1:
    raise newMcpError("WebSocket maxMessageBytes must be positive")
  if maxHeaderBytes < 1:
    raise newMcpError("WebSocket maxHeaderBytes must be positive")
  if maxNestingDepth < 1:
    raise newMcpError("WebSocket maxNestingDepth must be positive")
  if handshakeTimeoutMs < 0:
    raise newMcpError("WebSocket handshakeTimeoutMs must be at least 0")
  if requestTimeoutMs < 0:
    raise newMcpError("WebSocket requestTimeoutMs must be at least 0")
  McpWebSocketConfig(endpoint: endpoint, host: host, port: port,
    maxMessageBytes: maxMessageBytes, maxHeaderBytes: maxHeaderBytes,
    maxNestingDepth: maxNestingDepth, handshakeTimeoutMs: handshakeTimeoutMs,
    requestTimeoutMs: requestTimeoutMs,
    allowedHosts: allowedHosts, allowedOrigins: allowedOrigins,
    authorization: authorization)

proc newMcpWebSocketServer*(server: McpServer,
                            config = newMcpWebSocketConfig()):
                            McpWebSocketServer =
  if server.isNil: raise newMcpError("MCP server must not be nil")
  McpWebSocketServer(app: server, transport: newAsyncSocket(), config: config)

proc getPort*(server: McpWebSocketServer): Port =
  if server.isNil or not server.started:
    raise newMcpError("WebSocket server is not listening")
  server.transport.getLocalAddr[1]

proc headerValues(headers: openArray[WsHeader], name: string): seq[string] =
  for header in headers:
    if header.name.toLowerAscii == name.toLowerAscii:
      result.add header.value

proc headerValue(headers: openArray[WsHeader], name: string): string =
  let values = headers.headerValues(name)
  if values.len == 1: values[0]
  elif values.len > 1: values.join(",")
  else: ""

proc hasToken(value, expected: string): bool =
  for token in value.split(','):
    if token.strip.toLowerAscii == expected.toLowerAscii: return true

proc endpointPath(path: string): string =
  let query = path.find('?')
  if query < 0: path else: path[0 ..< query]

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

proc allowedHost(config: McpWebSocketConfig, headers: openArray[WsHeader]): bool =
  if config.allowedHosts.len == 0: return true
  let values = headers.headerValues("Host")
  if values.len != 1: return false
  let host = values[0].strip.toLowerAscii
  let hostname = hostWithoutPort(host)
  for allowed in config.allowedHosts:
    let value = allowed.strip.toLowerAscii
    if host == value or (value == hostWithoutPort(value) and hostname == value):
      return true

proc allowedOrigin(config: McpWebSocketConfig,
                   headers: openArray[WsHeader]): bool =
  let values = headers.headerValues("Origin")
  if values.len == 0: return true
  if values.len != 1: return false
  for allowed in config.allowedOrigins:
    if allowed == "*" or allowed == values[0]: return true

proc authorizationHeaders(headers: openArray[WsHeader]): seq[McpAuthHeader] =
  for header in headers:
    result.add McpAuthHeader(name: header.name, value: header.value)

proc httpReason(status: int): string =
  case status
  of 101: "Switching Protocols"
  of 400: "Bad Request"
  of 401: "Unauthorized"
  of 403: "Forbidden"
  of 404: "Not Found"
  of 405: "Method Not Allowed"
  of 408: "Request Timeout"
  of 426: "Upgrade Required"
  else: "Error"

proc sendHttpError(socket: AsyncSocket, status: int, message: string):
    Future[void] {.async.} =
  let body = message & "\n"
  try:
    await socket.send("HTTP/1.1 " & $status & " " & httpReason(status) &
      "\r\nConnection: close\r\nContent-Type: text/plain; charset=utf-8\r\n" &
      "Content-Length: " & $body.len & "\r\n\r\n" & body)
  except CatchableError:
    discard

proc rejectHandshake(socket: AsyncSocket, status: int,
                     message: string): Future[bool] {.async.} =
  await sendHttpError(socket, status, message)
  false

proc readHeaderBlock(socket: AsyncSocket, maxBytes: int,
                     timeoutMs: int): Future[string] {.async.} =
  var pending = newFuture[string]("mcpWebSocketHeaders")
  proc read {.async.} =
    try:
      var value = ""
      while not value.endsWith("\r\n\r\n"):
        let chunk = await socket.recv(1)
        if chunk.len == 0:
          raise newException(WsPeerClosed, "WebSocket peer closed")
        value.add chunk
        if value.len > maxBytes:
          raise protocolFault(1002, "WebSocket handshake headers are too large")
      pending.complete(value)
    except CatchableError as error:
      if not pending.finished: pending.fail(error)
  asyncCheck read()
  if timeoutMs > 0 and not await withTimeout(pending, timeoutMs):
    raise protocolFault(1002, "WebSocket handshake timed out")
  result = await pending

proc parseHeaders(headerBlock: string): tuple[methodName, target: string,
                                                headers: seq[WsHeader]] =
  let lines = headerBlock.split("\r\n")
  if lines.len < 3:
    raise protocolFault(1002, "Invalid WebSocket handshake")
  let requestLine = strutils.splitWhitespace(lines[0])
  if requestLine.len != 3 or requestLine[2] != "HTTP/1.1":
    raise protocolFault(1002, "Invalid WebSocket request line")
  result.methodName = requestLine[0]
  result.target = requestLine[1]
  for line in lines[1 ..< lines.len - 2]:
    let separator = line.find(':')
    if separator <= 0:
      raise protocolFault(1002, "Invalid WebSocket header")
    let name = line[0 ..< separator]
    let value = line[separator + 1 .. ^1].strip
    if '\r' in value or '\n' in value:
      raise protocolFault(1002, "Invalid WebSocket header value")
    result.headers.add WsHeader(name: name, value: value)

proc handshake(connection: McpWebSocketConnection): Future[bool] {.async.} =
  var headerBlock: string
  try:
    headerBlock = await readHeaderBlock(connection.socket,
      connection.server.config.maxHeaderBytes,
      connection.server.config.handshakeTimeoutMs)
  except WsPeerClosed:
    return false
  except CatchableError:
    return await rejectHandshake(connection.socket, 400,
      "Invalid WebSocket handshake")

  var parsed: tuple[methodName, target: string, headers: seq[WsHeader]]
  try:
    parsed = parseHeaders(headerBlock)
  except CatchableError:
    return await rejectHandshake(connection.socket, 400,
      "Invalid WebSocket handshake")

  let endpoint = endpointPath(parsed.target)
  if parsed.methodName != "GET":
    return await rejectHandshake(connection.socket, 405,
      "WebSocket handshake requires GET")
  if endpoint != connection.server.config.endpoint:
    return await rejectHandshake(connection.socket, 404, "Not Found")
  if parsed.headers.headerValues("Host").len != 1 or
      parsed.headers.headerValue("Host").len == 0:
    return await rejectHandshake(connection.socket, 400, "Host header is required")
  if not allowedHost(connection.server.config, parsed.headers):
    return await rejectHandshake(connection.socket, 403, "Forbidden host")
  if not allowedOrigin(connection.server.config, parsed.headers):
    return await rejectHandshake(connection.socket, 403, "Forbidden origin")
  if parsed.headers.headerValue("Upgrade").toLowerAscii != "websocket" or
      not hasToken(parsed.headers.headerValue("Connection"), "upgrade"):
    return await rejectHandshake(connection.socket, 400,
      "WebSocket upgrade headers are required")
  if parsed.headers.headerValue("Sec-WebSocket-Version") != "13":
    return await rejectHandshake(connection.socket, 426,
      "WebSocket version 13 is required")

  let key = parsed.headers.headerValue("Sec-WebSocket-Key").strip
  try:
    if decode(key).len != 16:
      raise newException(ValueError, "invalid key")
  except CatchableError:
    return await rejectHandshake(connection.socket, 400,
      "Sec-WebSocket-Key must be a valid 16-byte value")

  if connection.server.config.authorization.enabled:
    let decision = connection.server.config.authorization.authorize(
      newMcpAuthorizationRequest("GET", endpoint,
        connection.server.config.authorization.resource,
        parsed.headers.authorizationHeaders()))
    if not decision.allowed:
      let challenge = if decision.status == 403:
        authorizationChallenge(connection.server.config.authorization,
          "insufficient_scope", decision.scopes.join(" "))
      else: authorizationChallenge(connection.server.config.authorization)
      let body = decision.message & "\n"
      try:
        await connection.socket.send("HTTP/1.1 " & $decision.status & " " &
          httpReason(decision.status) & "\r\nConnection: close\r\n" &
          "WWW-Authenticate: " & challenge & "\r\nContent-Length: " &
          $body.len & "\r\n\r\n" & body)
      except CatchableError:
        discard
      return false
    connection.principal = decision.principal

  let handshakeValue = key & "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"
  let accept = encode(sha1.digest(
    handshakeValue.toOpenArray(0, handshakeValue.high)).data)
  try:
    await connection.socket.send("HTTP/1.1 101 Switching Protocols\r\n" &
      "Upgrade: websocket\r\nConnection: Upgrade\r\n" &
      "Sec-WebSocket-Accept: " & accept & "\r\n\r\n")
  except CatchableError:
    return false
  connection.path = endpoint
  true

proc readExact(socket: AsyncSocket, size: int): Future[string] {.async.} =
  result = newString(size)
  var offset = 0
  while offset < size:
    let chunk = await socket.recv(size - offset)
    if chunk.len == 0:
      raise newException(WsPeerClosed, "WebSocket peer closed")
    copyMem(addr result[offset], unsafeAddr chunk[0], chunk.len)
    offset += chunk.len

proc readUInt(socket: AsyncSocket, size: int): Future[uint64] {.async.} =
  let bytes = await readExact(socket, size)
  for byte in bytes:
    result = (result shl 8) or byte.ord.uint64

proc readFrame(connection: McpWebSocketConnection): Future[WsFrame] {.async.} =
  let first = (await readExact(connection.socket, 1))[0].ord
  let second = (await readExact(connection.socket, 1))[0].ord
  if (first and 0x70) != 0:
    raise protocolFault(1002, "WebSocket extensions are not supported")
  result.fin = (first and 0x80) != 0
  result.opcode = first and 0x0f
  if result.opcode notin [0, 1, 2, 8, 9, 10]:
    raise protocolFault(1002, "Invalid WebSocket opcode")
  let masked = (second and 0x80) != 0
  if not masked:
    raise protocolFault(1002, "Client WebSocket frames must be masked")
  var length = uint64(second and 0x7f)
  if length == 126:
    length = await readUInt(connection.socket, 2)
  elif length == 127:
    length = await readUInt(connection.socket, 8)
    if (length shr 63) != 0:
      raise protocolFault(1002, "Invalid WebSocket payload length")
  if result.opcode >= 8 and (not result.fin or length > 125):
    raise protocolFault(1002, "Invalid WebSocket control frame")
  if result.opcode < 8 and length > uint64(connection.server.config.maxMessageBytes):
    raise protocolFault(1009, "WebSocket message exceeds maximum size")
  if length > uint64(int.high):
    raise protocolFault(1009, "WebSocket payload is too large")
  let mask = await readExact(connection.socket, 4)
  result.payload = await readExact(connection.socket, int(length))
  for index in 0 ..< result.payload.len:
    result.payload[index] = char(result.payload[index].ord xor
      mask[index mod 4].ord)

proc encodeFrame(payload: string, opcode: int): string =
  result = newStringOfCap(payload.len + 10)
  result.add char(0x80 or opcode)
  if payload.len < 126:
    result.add char(payload.len)
  elif payload.len <= 0xffff:
    result.add char(126)
    result.add char((payload.len shr 8) and 0xff)
    result.add char(payload.len and 0xff)
  else:
    result.add char(127)
    for shift in countdown(7, 0):
      result.add char((payload.len.uint64 shr (shift * 8)) and 0xff)
  result.add payload

proc sendFrame(connection: McpWebSocketConnection,
               payload: string, opcode: int): Future[void] =
  if connection.closed:
    let failed = newFuture[void]("mcpWebSocketClosed")
    failed.fail(newException(McpWebSocketError,
      "WebSocket connection is closed"))
    return failed
  let previous = connection.writeTail
  let current = newFuture[void]("mcpWebSocketFrame")
  connection.writeTail = current
  let encoded = encodeFrame(payload, opcode)
  proc write {.async.} =
    try:
      if not previous.isNil: await previous
      if not connection.closed:
        await connection.socket.send(encoded)
      if not current.finished: current.complete()
    except CatchableError as error:
      if not current.finished: current.fail(error)
  asyncCheck write()
  current

proc sendJson(connection: McpWebSocketConnection,
              value: JsonNode): Future[void] {.async.} =
  if not value.isNil:
    await connection.sendFrame($value, 1)

proc closeFrame(connection: McpWebSocketConnection,
                code: uint16, reason = ""): Future[void] {.async.} =
  if connection.closeSent: return
  connection.closeSent = true
  var payload = newStringOfCap(reason.len + 2)
  payload.add char(code shr 8)
  payload.add char(code and 0xff)
  payload.add reason
  try:
    await connection.sendFrame(payload, 8)
  except CatchableError:
    discard

proc readMessage(connection: McpWebSocketConnection): Future[WsMessage] {.async.} =
  var fragmented = false
  var message = ""
  while true:
    let frame = await readFrame(connection)
    case frame.opcode
    of 8:
      if frame.payload.len == 1:
        raise protocolFault(1002, "Invalid WebSocket close frame")
      await connection.closeFrame(1000)
      return WsMessage(closed: true)
    of 9:
      await connection.sendFrame(frame.payload, 10)
    of 10:
      discard
    of 1:
      if fragmented:
        raise protocolFault(1002, "Nested WebSocket data frame")
      fragmented = not frame.fin
      message = frame.payload
      if frame.fin:
        break
    of 0:
      if not fragmented:
        raise protocolFault(1002, "Unexpected WebSocket continuation")
      message.add frame.payload
      if message.len > connection.server.config.maxMessageBytes:
        raise protocolFault(1009, "WebSocket message exceeds maximum size")
      if frame.fin:
        fragmented = false
        break
    of 2:
      raise protocolFault(1003, "MCP WebSocket messages must be text")
    else:
      raise protocolFault(1002, "Invalid WebSocket frame")
  if validateUtf8(message) >= 0:
    raise protocolFault(1007, "WebSocket text message must be UTF-8")
  WsMessage(payload: message)

proc removeContext(connection: McpWebSocketConnection, context: McpContext) =
  for index in countdown(connection.contexts.high, 0):
    if connection.contexts[index] == context:
      connection.contexts.delete(index)
      break

proc forwardSubscription(connection: McpWebSocketConnection,
                         server: McpServer, id: McpId,
                         message: JsonNode): Future[void] {.async.} =
  try:
    await connection.sendJson(message)
  except CatchableError:
    discard server.cancelSubscription(id)

proc sendError(connection: McpWebSocketConnection, id: McpId,
               code: int, message: string, data: JsonNode = nil): Future[void]
               {.async.} =
  await connection.sendJson(toJson(errorResponse(id, code, message, data)))

proc dispatchMessage(connection: McpWebSocketConnection,
                     payload: string): Future[void] {.async.} =
  var value: JsonNode
  try:
    value = parseJson(payload)
  except CatchableError:
    await connection.sendError(McpId(kind: mcpNullId), mcpParseErrorCode,
      "Parse error")
    return

  let notification = value.kind == JObject and "id" notin value
  var message: McpJsonRpcMessage
  try:
    message = parseMcpMessage(value,
      maxNestingDepth = connection.server.config.maxNestingDepth)
  except McpError as error:
    if not notification:
      await connection.sendError(requestIdOrNull(value), error.code,
        error.msg, error.data)
    return

  if message.kind notin {mcpRequestMessage, mcpNotificationMessage}:
    await connection.sendError(McpId(kind: mcpNullId), mcpInvalidRequestCode,
      "WebSocket transport accepts requests and notifications only")
    return

  let request = message.request
  let notificationSender: McpNotificationSender =
    proc (notification: JsonNode): Future[void] {.async.} =
      await connection.sendJson(notification)
  let context = newMcpContext(request,
    McpTransportInfo(kind: mcpTransportWebSocket, name: "websocket",
      endpoint: connection.path, remoteAddress: connection.remoteAddress),
    principal = connection.principal,
    notificationSender = notificationSender,
    deadlineMs = connection.server.config.requestTimeoutMs,
    requestBytes = payload.len)
  connection.contexts.add context
  defer: connection.removeContext(context)

  let requestId = if request.kind == mcpRequest: request.id else:
    McpId(kind: mcpNullId)
  let subscriptionHandler: McpSubscriptionMessageHandler =
    if request.methodName == "subscriptions/listen":
      proc (notification: JsonNode) =
        asyncCheck connection.forwardSubscription(connection.server.app,
          requestId, notification)
    else: nil
  let dispatch = connection.server.app.handleMessageAsync(message, context,
    subscriptionHandler)
  var output: Option[McpJsonRpcMessage]
  if connection.server.config.requestTimeoutMs > 0 and
      not await withTimeout(dispatch, connection.server.config.requestTimeoutMs):
    context.cancel("WebSocket request timeout")
    await connection.sendError(requestId, mcpInternalErrorCode,
      "MCP request timed out")
    return
  output = await dispatch
  if request.methodName == "subscriptions/listen" and output.isNone:
    let subscription = connection.server.app.findSubscription(request.id)
    if not subscription.isNil: connection.subscriptions.add subscription
  if output.isSome:
    await connection.sendJson(toJson(output.get))

proc closeConnection(connection: McpWebSocketConnection) =
  if connection.isNil or connection.closed: return
  connection.closed = true
  for context in connection.contexts:
    context.cancel("WebSocket connection closed")
  for subscription in connection.subscriptions:
    discard connection.server.app.closeSubscription(subscription, graceful = false)
  connection.socket.close()

proc removeConnection(server: McpWebSocketServer,
                      connection: McpWebSocketConnection) =
  for index in countdown(server.connections.high, 0):
    if server.connections[index] == connection:
      server.connections.delete(index)
      break
  dec server.activeConnections

proc handleConnection(server: McpWebSocketServer,
                       connection: McpWebSocketConnection): Future[void]
                       {.async.} =
  try:
    if await connection.handshake():
      while not connection.closed:
        let message = await connection.readMessage()
        if message.closed: break
        await connection.dispatchMessage(message.payload)
  except WsProtocolFault as error:
    await connection.closeFrame(error.code, error.msg)
  except WsPeerClosed:
    discard
  except CatchableError:
    await connection.closeFrame(1011, "WebSocket transport failure")
  finally:
    connection.closeConnection()
    server.removeConnection(connection)

proc serveWebSocket*(server: McpWebSocketServer): Future[void] {.async.} =
  if server.isNil: raise newMcpError("WebSocket server must not be nil")
  if server.started: raise newMcpError("WebSocket server is already listening")
  server.transport.bindAddr(server.config.port, server.config.host)
  server.transport.listen()
  server.started = true
  try:
    while not server.stopping:
      try:
        let socket = await server.transport.accept()
        let connection = McpWebSocketConnection(server: server, socket: socket)
        connection.remoteAddress = socket.getPeerAddr[0]
        server.connections.add connection
        inc server.activeConnections
        asyncCheck server.handleConnection(connection)
      except CatchableError:
        if not server.stopping: raise
  finally:
    server.stopping = true
    discard server.app.cancelActiveRequests()
    for connection in server.connections:
      connection.closeConnection()
    server.transport.close()
  while server.activeConnections > 0:
    await sleepAsync(10)

proc shutdown*(server: McpWebSocketServer) =
  if server.isNil: return
  server.stopping = true
  discard server.app.cancelActiveRequests()
  if server.started: server.transport.close()
  for connection in server.connections:
    connection.closeConnection()
