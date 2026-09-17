import std/[asyncdispatch, json, nativesockets]

import ../src/nimwire

let app = mcpServer("websocket-example", "1.0.0"):
  server.addTool mcpTool("echo", "Echo text", %*{
    "type": "object",
    "properties": {"text": {"type": "string"}},
    "required": ["text"]
  }, proc (args: JsonNode, ignoredContext: McpContext): McpToolResult =
    textResult(args["text"].getStr))

let websocket = newMcpWebSocketServer(app, newMcpWebSocketConfig(
  endpoint = "/mcp", host = "127.0.0.1", port = Port(8080)))

waitFor websocket.serveWebSocket()
