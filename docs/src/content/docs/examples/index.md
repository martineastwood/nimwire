---
title: Examples
description: Runnable MCP server examples for nimwire.
---

These examples are complete Nim programs from the repository's [`examples/`](https://github.com/martineastwood/nimwire/tree/main/examples) directory.

Compile an example from the `nimwire` package directory:

```sh
nim c examples/echo_server.nim
```

Run the resulting executable with an MCP client, or pipe newline-delimited JSON-RPC into the stdio examples.

- [Echo server](./echo-server): register one tool and serve stdio.
- [HTTP server](./http-server): serve the same style of tool over Streamable HTTP.
- [Prompts server](./prompts-server): define a typed prompt and completion hook.
- [Resources server](./resources-server): serve files, generated data, and URLs.
- [Auth server](./auth-server): enable bearer authorization and scope checks.

The HTTP example also includes a minimal [reverse proxy configuration](https://github.com/martineastwood/nimwire/blob/main/examples/reverse_proxy.conf).

The examples import `../src/nimwire`, so they run directly from a checkout. Installed applications can use `import nimwire` instead.
