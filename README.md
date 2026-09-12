# nimwire

MCP server primitives for Nim.

The first release targets the stable MCP `2026-07-28` revision over stdio and
Streamable HTTP:

- stateless per-request metadata;
- `server/discover`, `ping`, `tools/list`, `tools/call`, `prompts/list`, and
  `prompts/get`;
- deterministic tool discovery with cache hints;
- tool metadata, JSON Schema validation, structured results, and pagination;
- static and dynamic resources, URI templates, binary contents, and safe file
  resource helpers;
- typed prompts with text, media, resource-link, and embedded-resource messages;
- prompt and resource-template completion with bounded result hints;
- stateless multi-round-trip input requests with elicitation, sampling, and
  roots handlers;
- opt-in `subscriptions/listen` change streams for tools, prompts, and resources;
- sync and async tool handlers;
- a small declarative `mcpServer` template/macro API.

The implementation is split into focused modules. Import `nimwire/core` for
protocol primitives, `nimwire/server` for registration and dispatch,
`nimwire/resources` for resource definitions and helpers, `nimwire/prompts` for
prompt definitions and messages, and
`nimwire/transports/stdio` for the stdio transport. `nimwire/context` provides
request-scoped handler context, `nimwire/mrtr` provides multi-round-trip input
handling, while `nimwire/testing` provides in-process request helpers.

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

Every tool handler receives request context as its second parameter. Use an
ignored parameter when a tool does not need it:

```nim
server.addTool mcpTool("whoami", "Read the caller", %*{"type": "object"},
  proc (args: JsonNode, context: McpContext): McpToolResult =
    textResult(context.principal.subject))
```

`McpStateStore` provides expiring, subject-bound opaque handles when a workflow
needs to carry state across otherwise stateless requests.

Resources use typed text or base64-encoded blob contents:

```nim
server.addResource newMcpResource("memo://today", "Today's memo",
  resourceText("memo://today", "Ship it", "text/plain"))

server.addResource newFileResource(getCurrentDir(), "README.md",
  uriValue = "file:///project/README.md", mimeType = "text/markdown")
```

Use `newMcpResourceTemplate` for parameterized resources and
`newFileResourceTemplate` for confined file access. `safeResourcePath` rejects
traversal and symlink escapes before a file is read. See
`examples/resources_server.nim` for file, generated-data, database-schema,
and HTTP URL examples. Resource change subscriptions receive wire-ready
notification JSON through `subscriptions/listen`; call `markToolsChanged`,
`markPromptsChanged`, `markResourcesChanged`, or `markResourceUpdated` after
application data changes. Supply `eventBus = newMcpEventBus(...)` to
`newMcpServer` when change events need an external publisher.

Prompts expose typed string arguments and MCP message content:

```nim
server.addPrompt mcpPrompt("review",
  proc (arguments: McpPromptArguments,
        ignoredContext: McpContext): McpPromptMessage =
    userText("Review this code:\n" & getPromptArgument(arguments, "code")),
  description = "Review a code snippet",
  arguments = @[newMcpPromptArgument("code", required = true)])
```

Use `server.addPromptCompletion` to attach a completion hook to a declared
prompt argument; `prompts/list` and `prompts/get` are dispatched by the server.
The `completion/complete` endpoint accepts `ref/prompt` and `ref/resource`
references and returns at most 100 suggestions with `total` and `hasMore`
hints. Completion handlers can inspect prior values through
`context.completionArguments`.

Use `context.requireInput(newMcpInputRequiredResult(...))` from a tool, prompt,
or resource handler when more client input is needed. `McpInputClient` validates
elicitation form responses, preserves opaque `requestState`, and creates a fresh
JSON-RPC ID for each retry. Configure `requestStateSealer` and
`requestStateVerifier` on `newMcpServer` when state needs authenticated sealing.
