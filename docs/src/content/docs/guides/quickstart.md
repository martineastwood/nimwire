---
title: Quickstart
description: Build and run your first nimwire MCP server.
---

This guide takes you from an empty Nim file to a server that responds to MCP clients over stdio.

## 1. Install nimwire

You need Nim 2.0 or later. Install nimwire with Nimble:

```sh
nimble install nimwire
```

## 2. Create the server

Create `echo.nim`:

```nim
import nimwire

type EchoInput = object
  text*: string

let server = mcpServer("nimwire-echo", "0.1.0"):
  server.tool "echo", "Echo text back to the caller",
    proc (input: EchoInput): string =
      input.text

server.serveStdio()
```

`mcpServer` creates a server with the name and version supplied. `server.tool` derives the input schema from `EchoInput`, decodes the JSON arguments into that Nim object, and encodes the returned string for the MCP response.

## 3. Compile it

```sh
nim c echo.nim
```

The resulting `echo` executable waits for JSON-RPC messages on stdin. Keep stdout reserved for protocol output. Write diagnostics to stderr if you add logging around the server.

## 4. Send a request

You can make a small discovery request without an MCP client:

```sh
printf '%s\n' '{"jsonrpc":"2.0","id":1,"method":"server/discover","params":{"_meta":{"io.modelcontextprotocol/protocolVersion":"2026-07-28","io.modelcontextprotocol/clientCapabilities":{}}}}' | ./echo
```

The response advertises the server identity, the protocol version, and its available capabilities. An MCP client will perform discovery and then call `tools/list` and `tools/call` for you.

## Call the tool from JSON-RPC

The tool call body looks like this:

```json
{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"echo","arguments":{"text":"hello"},"_meta":{"io.modelcontextprotocol/protocolVersion":"2026-07-28","io.modelcontextprotocol/clientCapabilities":{}}}}
```

Every stdio message is one line. nimwire validates the JSON-RPC envelope and the tool arguments against the schema before invoking your handler.

## Try it with MCP Inspector

The [MCP Inspector](https://github.com/modelcontextprotocol/inspector) is the fastest way to exercise discovery and tool calls interactively. Point it at your compiled executable as a stdio server, or at an HTTP or WebSocket endpoint once you add a transport.

For manual debugging, pipe one JSON-RPC line at a time as shown above. Keep stdout reserved for protocol output and write diagnostics to stderr.

## Where to go next

- [Server basics](/guides/server-basics/): add more tools and return structured data.
- [Typed tools](/guides/tools/): derive schemas from Nim types.
- [Transports](/guides/transports/): expose the same server over HTTP.
- [Testing](/guides/testing/): test requests without starting a process.
