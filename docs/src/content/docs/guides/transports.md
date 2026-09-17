---
title: Transports
description: Serve nimwire over stdio, Streamable HTTP, WebSocket, or an in-process link.
---

The server registry is independent of delivery. Choose stdio when an MCP client launches your executable, Streamable HTTP or WebSocket for a network endpoint, or in-process transport when two Nim components share a process.

## Stdio

For local MCP servers, call:

```nim
server.serveStdio()
```

Use `serveStdioAsync` inside an existing async application. Both functions read one JSON-RPC message per line and write one response per line. The default message limit is 1 MiB and the default nesting limit is 64 levels:

```nim
server.serveStdio(
  maxMessageBytes = 2 * 1024 * 1024,
  maxNestingDepth = 64,
  securityLimits = newMcpSecurityLimits(maxLineBytes = 2 * 1024 * 1024))
```

Do not write human-readable logs to stdout. Stdio clients treat that stream as protocol data.

## Built-in HTTP server

The standard library adapter is enough for a small server:

```nim
import std/[asyncdispatch, nativesockets]
import nimwire

let app = mcpServer("http-example", "1.0.0"):
  discard

let http = newMcpHttpServer(app, newMcpHttpConfig(
  endpoint = "/mcp",
  host = "127.0.0.1",
  port = Port(8080),
  allowedHosts = @["127.0.0.1"]))

waitFor http.serveHttp()
```

`newMcpHttpServer` uses Nim's `asynchttpserver`. Call `http.shutdown()` from your application when it needs to stop accepting requests. The adapter cancels active requests and closes subscriptions during shutdown.

## Framework-neutral HTTP

Web frameworks can adapt their request object to `McpHttpRequest`, call `handleHttpRequest`, then write the returned `McpHttpResponse`. Populate the request's method, path, headers, body, cancellation signal, and optional stream callbacks. This keeps framework-specific routing outside nimwire.

```nim
import std/asyncdispatch
import nimwire

proc handleMyFrameworkRequest(server: McpServer, raw: MyRequest):
    Future[MyResponse] {.async.} =
  var request = newMcpHttpRequest(raw.method, raw.path, raw.body, raw.headers)
  request.cancellation = raw.cancellation
  let response = await server.handleHttpRequest(request, myHttpConfig)
  result.status = response.status
  result.headers = response.headers
  result.body = response.body
```

`toMcpHttpRequest` adapts Nim's `asynchttpserver.Request` when you only need the stdlib shape.

POST requests need `Content-Type: application/json`, an `Accept` header containing both `application/json` and `text/event-stream`, and headers that match the JSON body:

```text
MCP-Protocol-Version: 2026-07-28
Mcp-Method: tools/call
Mcp-Name: echo
```

Tool arguments can opt into additional `Mcp-Param-*` header checks with `x-mcp-header` in their schema. The header value must match the body value.

## HTTP limits and origins

Configure `maxBodyBytes`, `maxNestingDepth`, `requestTimeoutMs`, and `maxConcurrentRequests` in `newMcpHttpConfig`. `allowedHosts` protects the Host header. `allowedOrigins` controls CORS responses, and an empty list allows no cross-origin Origin value.

`preferSse = true` enables the standard adapter's event-stream response shape. Use a `streamWriter` when a framework adapter needs to send notifications or streamed responses as they arrive.

The built-in adapter does not terminate TLS. Put a public HTTP server behind TLS and a trusted reverse proxy. The repository includes a minimal [reverse proxy configuration](https://github.com/martineastwood/nimwire/blob/main/examples/reverse_proxy.conf).

## WebSocket

Use WebSocket when a client needs one long-lived, bidirectional connection. The
server accepts one MCP JSON-RPC request or notification per text message and
keeps the connection open for later requests, progress notifications, and
subscriptions:

```nim
import std/[asyncdispatch, json, nativesockets]
import nimwire

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

Run the complete example with:

```sh
nim c -r examples/websocket_server.nim
```

`newMcpWebSocketConfig` uses a 1 MiB message limit, 64 levels of JSON nesting,
and a 10-second handshake timeout by default. Set `requestTimeoutMs` to cancel
long-running MCP requests. Use `allowedHosts`, `allowedOrigins`, and
`authorization` when the endpoint is reachable by untrusted clients.

The built-in WebSocket server does not terminate TLS. Put it behind a trusted
TLS reverse proxy in production. WebSocket clients must send masked text
messages; browser WebSocket clients do this automatically.

## In-process transport

Link a server without a process or socket:

```nim
import nimwire

let upstream = newMcpServer("upstream", "1.0.0")
let peer = newMcpInProcessPeer(upstream)
let discovery = peer.request("server/discover")
echo discovery.fields
peer.close()
```

The in-process transport carries the same validated JSON-RPC values as other transports, which makes it useful for tests and [composition](/guides/composition/).

## Custom transports

When you already parse JSON-RPC yourself, call `handleMessageAsync` or `dispatchAsync` on `McpServer`. Build an `McpContext` with `newMcpContext`, attach a notification sender when the transport must emit progress or subscription events, and write the returned `McpJsonRpcMessage`. Stdio, HTTP, WebSocket, and in-process transports all use this boundary.

Related: [Security](/guides/security/) and the [HTTP API reference](/reference/api/nimwire/transports/http/).
