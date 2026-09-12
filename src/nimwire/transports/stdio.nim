## Newline-delimited JSON-RPC transport over stdin and stdout.

import std/[asyncdispatch, json, options, strutils]

import ../core
import ../context
import ../server

proc writeJson(message: JsonNode) =
  stdout.writeLine($message)
  flushFile(stdout)

proc writeResponse(message: McpJsonRpcMessage) =
  writeJson(toJson(message))

proc serveStdio*(server: McpServer,
                 maxMessageBytes = mcpDefaultMaxMessageBytes,
                 maxNestingDepth = mcpDefaultMaxNestingDepth) =
  if server.isNil: raise newMcpError("server must not be nil")
  while not endOfFile(stdin):
    let line = stdin.readLine()
    if line.strip.len == 0: continue
    try:
      let message = parseMcpMessage(line, maxMessageBytes, maxNestingDepth)
      let output = if message.kind in {mcpRequestMessage, mcpNotificationMessage}:
        let context = newMcpContext(message.request,
          McpTransportInfo(kind: mcpTransportStdio, name: "stdio"))
        if message.request.methodName == "subscriptions/listen":
          waitFor server.handleMessageAsync(message, context,
            proc (notification: JsonNode) = writeJson(notification))
        else:
          waitFor server.handleMessageAsync(message, context)
      else:
        waitFor server.handleMessageAsync(message, nil)
      if output.isSome:
        writeResponse(output.get)
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
