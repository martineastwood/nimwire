---
title: WebSocket server
description: Keep a bidirectional MCP connection open with nimwire's WebSocket transport.
---

The WebSocket example creates a persistent MCP endpoint at
`ws://127.0.0.1:8080/mcp`.

```nim
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
```

Run it from the `nimwire` package directory:

```sh
nim c -r examples/websocket_server.nim
```

Send one MCP JSON-RPC request or notification in each text WebSocket message.
The connection remains open for later requests, progress notifications, and
subscriptions. See [Transports](/guides/transports/) for message limits,
authorization, origins, and shutdown.

[View the source example](https://github.com/martineastwood/nimwire/blob/main/examples/websocket_server.nim)
