---
title: Introduction
description: Build MCP servers in Nim with typed tools, resources, prompts, and native transports.
---

nimwire gives you the server side of the [Model Context Protocol](https://modelcontextprotocol.io) in native Nim code. You can expose functions as tools, publish files or generated data as resources, offer reusable prompts, and serve the same application over stdio, Streamable HTTP, or WebSocket.

## Your first server

Install nimwire with Nimble, then create `echo.nim`:

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

Compile it with:

```sh
nimble install nimwire
nim c echo.nim
```

The executable reads newline-delimited JSON-RPC messages from stdin and writes responses to stdout. An MCP client normally launches it for you.

## What you can build

- **Tools:** use typed Nim procedures and let nimwire derive their input and output schemas, or provide raw JSON when you need full schema control.
- **Resources:** serve static text, generated data, binary contents, files, and URI templates.
- **Prompts:** return text, media, resource links, or embedded resources from typed string arguments.
- **Transports:** use stdio for local clients, Streamable HTTP or WebSocket for remote clients, or an in-process transport for composition and tests.
- **Long-running work:** opt into MCP Tasks with expiring in-memory storage or durable storage callbacks.
- **Multi-round-trip input:** pause a tool, prompt, or resource call with `input_required` and resume on the next request.
- **Production features:** add authorization, principal-based visibility, cancellation, progress, limits, request logs, metrics, and tracing hooks.

## A small, focused API

Most applications can start with the umbrella import:

```nim
import nimwire
```

As the application grows, focused imports such as `nimwire/server`, `nimwire/resources`, or `nimwire/transports/http` keep compile-time dependencies obvious. The [API reference](/reference/core-api/) lists the public modules and entry points.

## Next steps

- [Quickstart](/guides/quickstart/): build, run, and inspect a complete stdio server.
- [Server basics](/guides/server-basics/): register tools and understand MCP responses.
- [Multi-round-trip input](/guides/mrtr/): ask for confirmation or client-side input across requests.
- [Transports](/guides/transports/): choose stdio, HTTP, WebSocket, or in-process delivery.
- [Examples](/examples/): copy the runnable servers from the repository.
