## Newline-delimited JSON-RPC transport over stdin and stdout.

import std/[asyncdispatch, asyncfile, json, options, strutils]

import ../core
import ../context
import ../security
import ../server

proc writeJson(message: JsonNode) =
  stdout.writeLine($message)
  flushFile(stdout)

proc writeResponse(message: McpJsonRpcMessage) =
  writeJson(toJson(message))

proc dispatchStdioMessage(server: McpServer, message: McpJsonRpcMessage,
                          requestBytes: int):
    Future[void] {.async.} =
  let notificationSender: McpNotificationSender =
    proc (notification: JsonNode): Future[void] {.async.} =
      writeJson(notification)
  let isRequest = message.kind in {mcpRequestMessage, mcpNotificationMessage}
  var context: McpContext
  if isRequest:
    context = newMcpContext(message.request,
      McpTransportInfo(kind: mcpTransportStdio, name: "stdio"),
      notificationSender = notificationSender, requestBytes = requestBytes)
  let output = if isRequest:
    if message.request.methodName == "subscriptions/listen":
      await server.handleMessageAsync(message, context,
        proc (notification: JsonNode) = writeJson(notification))
    else:
      await server.handleMessageAsync(message, context)
  else:
    await server.handleMessageAsync(message, nil)
  if output.isSome:
    writeResponse(output.get)

type
  StdioLine = object
    value: string
    tooLarge: bool
    eof: bool

proc readStdioLine(input: AsyncFile, maxBytes: int): Future[StdioLine] {.async.} =
  while true:
    let chunk = await input.read(1)
    if chunk.len == 0:
      result.eof = true
      return
    if chunk[0] in {'\r', '\n'}:
      return
    if result.value.len < maxBytes:
      result.value.add chunk[0]
    else:
      result.tooLarge = true

proc serveStdioAsync*(server: McpServer,
                      maxMessageBytes = mcpDefaultMaxMessageBytes,
                      maxNestingDepth = mcpDefaultMaxNestingDepth,
                      securityLimits = McpSecurityLimits()): Future[void] {.async.} =
  if server.isNil: raise newMcpError("server must not be nil")
  validateSecurityLimits(securityLimits)
  let lineLimit = if securityLimits.maxLineBytes > 0:
    min(maxMessageBytes, securityLimits.maxLineBytes)
  else: maxMessageBytes
  let input = newAsyncFile(AsyncFD(getFileHandle(stdin)))
  var pending: seq[Future[void]]
  while true:
    let read = await readStdioLine(input, lineLimit)
    if read.eof and read.value.len == 0: break
    let line = read.value
    if line.strip.len == 0: continue
    if read.tooLarge:
      writeResponse(errorResponse(McpId(kind: mcpNullId), mcpParseErrorCode,
        "JSON line exceeds maximum size"))
      continue
    try:
      let message = parseMcpMessage(line, maxMessageBytes, maxNestingDepth)
      pending.add server.dispatchStdioMessage(message, line.len)
    except McpError as error:
      if error.code == mcpParseErrorCode:
        writeResponse(errorResponse(McpId(kind: mcpNullId), error.code,
          error.msg, error.data))
        continue
      var request: JsonNode
      try:
        request = parseJson(line)
      except CatchableError:
        writeResponse(errorResponse(McpId(kind: mcpNullId),
          mcpParseErrorCode, "Parse error"))
        continue
      if request.kind == JObject and "id" notin request: continue
      writeResponse(errorResponse(requestIdOrNull(request), error.code,
        error.msg, error.data))
  for task in pending:
    await task

proc serveStdio*(server: McpServer,
                 maxMessageBytes = mcpDefaultMaxMessageBytes,
                 maxNestingDepth = mcpDefaultMaxNestingDepth,
                 securityLimits = McpSecurityLimits()) =
  waitFor server.serveStdioAsync(maxMessageBytes, maxNestingDepth,
    securityLimits)
