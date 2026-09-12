# nimwire

MCP server primitives for Nim.

The first release targets the stable MCP `2026-07-28` revision over stdio:

- stateless per-request metadata;
- `server/discover`, `ping`, `tools/list`, and `tools/call`;
- deterministic tool discovery with cache hints;
- sync and async tool handlers;
- a small declarative `mcpServer` template/macro API.

Build the example:

```sh
nim c examples/echo_server.nim
```

The resulting executable speaks newline-delimited JSON-RPC on stdin/stdout.
