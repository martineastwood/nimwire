import std/[asyncdispatch, json, nativesockets]

import ../src/nimwire

let app = mcpServer("http-example", "1.0.0"):
  server.addTool mcpTool("echo", "Echo text", %*{
    "type": "object",
    "properties": {"text": {"type": "string"}},
    "required": ["text"]
  }, proc (args: JsonNode, ignoredContext: McpContext): McpToolResult =
    textResult(args["text"].getStr))

let http = newMcpHttpServer(app, newMcpHttpConfig(
  endpoint = "/mcp", host = "127.0.0.1", port = Port(8080),
  allowedHosts = @["127.0.0.1"]))

waitFor http.serveHttp()
