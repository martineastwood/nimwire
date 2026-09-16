---
title: HTTP server
description: Serve an MCP tool with nimwire's standard library HTTP adapter.
---

The HTTP example creates a local endpoint at `http://127.0.0.1:8080/mcp`.

```nim
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
```

Run it with:

```sh
nim c -r examples/http_server.nim
```

The framework-neutral `handleHttpRequest` API lets you adapt the same app to another Nim web framework. See [Transports](/guides/transports/) for request headers and HTTP limits.

[View the source example](https://github.com/martineastwood/nimwire/blob/main/examples/http_server.nim)
