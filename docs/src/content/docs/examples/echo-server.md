---
title: Echo server
description: Register a typed tool and serve it over stdio.
---

This is the smallest complete nimwire server. It exposes a typed `echo` tool and speaks newline-delimited JSON-RPC on stdin and stdout.

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

Compile it from the package directory:

```sh
nim c examples/echo_server.nim
```

[View the source example](https://github.com/martineastwood/nimwire/blob/main/examples/echo_server.nim)
