---
title: Testing
description: Exercise MCP requests without starting a process or using a network socket.
---

Use `nimwire/testing` for fast request-level tests. The helpers send the same JSON-RPC shapes the transports dispatch, including the current protocol metadata.

## Test a tool call

```nim
import std/[json, unittest]
import nimwire
import nimwire/testing

suite "echo server":
  test "returns text":
    let server = mcpServer("test", "1.0.0"):
      server.addTool mcpTool("echo", "Echo text", %*{
        "type": "object",
        "properties": {"text": {"type": "string"}},
        "required": ["text"]
      }, proc (args: JsonNode,
               context: McpContext): McpToolResult =
        textResult(args["text"].getStr))

    let response = server.sendRequest(modernRequest(1, "tools/call", %*{
      "name": "echo",
      "arguments": {"text": "hello"}
    }))

    check response["result"]["resultType"].getStr == "complete"
    check response["result"]["content"][0]["text"].getStr == "hello"
```

`modernRequest` adds the JSON-RPC version, the `2026-07-28` protocol version, and empty client capabilities. `sendRequest` calls the server's blocking JSON boundary and returns the encoded response.

## Assert protocol errors

Send invalid arguments or an unknown method and inspect the `error` object:

```nim
let response = server.sendRequest(modernRequest(2, "tools/call", %*{
  "name": "missing",
  "arguments": {}
}))

check response["error"]["code"].getInt == mcpInvalidParamsCode
```

Use `handleJsonAsync` when the test already runs an async event loop.

## Test transport behavior

Use `newMcpInProcessPeer` to exercise request and notification handling through a linked transport:

```nim
let peer = newMcpInProcessPeer(server)
let result = peer.request("server/discover")
check result.resultType == mcpComplete
peer.close()
```

This is useful for composition and message-level behavior. It does not test HTTP headers, CORS, socket disconnects, or stdio framing. Use a local HTTP request adapter or fixture when those boundaries matter.

Related: [Transports](/guides/transports/) and the [testing API reference](/reference/api/nimwire/testing/).
