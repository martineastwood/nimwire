import std/json
import nimwire

let server = mcpServer("nimwire-echo", "0.1.0"):
  server.addTool mcpTool("echo", "Echo text back to the caller", %*{
    "type": "object",
    "properties": {"text": {"type": "string"}},
    "required": ["text"]
  }, proc (args: JsonNode): McpToolResult =
    textResult(args["text"].getStr))

server.serveStdio()
