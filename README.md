# nimwire

MCP server primitives for Nim.

The first release targets the stable MCP `2026-07-28` revision over stdio and
Streamable HTTP:

- stateless per-request metadata;
- `server/discover`, `ping`, `tools/list`, and `tools/call`;
- deterministic tool discovery with cache hints;
- tool metadata, JSON Schema validation, structured results, and pagination;
- sync and async tool handlers;
- a small declarative `mcpServer` template/macro API.

The implementation is split into focused modules. Import `nimwire/core` for
protocol primitives, `nimwire/server` for registration and dispatch, and
`nimwire/transports/stdio` for the stdio transport. `nimwire/testing` provides
in-process request helpers.

Use `parseMcpMessage` and `toJson` at custom transport boundaries. The parser
enforces a 1 MiB message limit and 64 levels of nesting by default; both are
configurable.

Build the example:

```sh
nim c examples/echo_server.nim
```

The resulting executable speaks newline-delimited JSON-RPC on stdin/stdout.

Run the HTTP example:

```sh
nim c -r examples/http_server.nim
```

It serves stateless POST requests at `http://127.0.0.1:8080/mcp`. The HTTP
transport is framework-neutral: adapt a request into `McpHttpRequest`, call
`handleHttpRequest`, and write the returned `McpHttpResponse` in any web
framework. `newMcpHttpServer` also provides a small stdlib
`asynchttpserver` adapter. See [examples/reverse_proxy.conf](examples/reverse_proxy.conf)
for a minimal deployment shape.
