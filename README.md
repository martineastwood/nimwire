# nimwire

MCP server primitives for Nim.

The first release targets the stable MCP `2026-07-28` revision over stdio,
Streamable HTTP, and persistent WebSocket connections:

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
- cooperative cancellation, progress notifications, request/tool deadlines,
  and shutdown cancellation;
- pluggable HTTP bearer authorization with protected-resource metadata and
  principal-based feature filters;
- bounded security controls, redaction helpers, HTTPS URL validation, and
  confined filesystem helpers;
- structured request logs, trace context, metrics, correlation IDs, and
  optional OpenTelemetry-friendly span hooks;
- opt-in MCP Tasks with durable-store hooks, polling, input updates, and
  cancellation;
- transport-neutral typed message handling, linked in-process transports, and
  collision-safe remote server composition;
- generic finalized extension registration with capability negotiation and
  schema-validated methods;
- sync and async tool handlers;
- a small declarative `mcpServer` template/macro API.

The implementation is split into focused modules. Import `nimwire/core` for
protocol primitives, `nimwire/server` for registration and dispatch,
`nimwire/resources` for resource definitions and helpers, `nimwire/prompts` for
prompt definitions and messages, and
`nimwire/transports/stdio` for the stdio transport and
`nimwire/transports/websocket` for persistent WebSocket connections.
`nimwire/context` provides
request-scoped handler context, `nimwire/mrtr` provides multi-round-trip input
handling, `nimwire/auth` provides HTTP authorization hooks, `nimwire/security`
provides reusable limits and redaction, while `nimwire/testing` provides
in-process request helpers. `nimwire/transport` defines the generic typed
message transport and `McpPeer` request/response helper, while
`nimwire/transports/inproc` links a server without a process or socket.
`nimwire/composition` mounts a discovered remote peer's tools, resources, and
prompts under a required namespace. `nimwire/tasks` adds the opt-in Tasks
extension and `nimwire/extensions` adds generic extension registration.
`nimwire/middleware` contains composable tool middleware helpers.

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

Run the WebSocket example:

```sh
nim c -r examples/websocket_server.nim
```

It accepts masked text WebSocket messages at `ws://127.0.0.1:8080/mcp`. Each
message contains one MCP JSON-RPC request or notification. The connection stays
open for subsequent messages, progress notifications, and subscriptions.

Raw tool handlers receive request context as their second parameter. Use an
ignored parameter when a tool does not need it:

```nim
server.addTool mcpTool("whoami", "Read the caller", %*{"type": "object"},
  proc (args: JsonNode, context: McpContext): McpToolResult =
    textResult(context.principal.subject))
```

For typed tools, `server.tool` derives the MCP input and output schemas and
generates JSON decoding/encoding at compile time:

```nim
type Weather = object
  temperature*: int
  condition*: string

server.tool "weather", "Current weather",
  proc (city: string): Weather = lookupWeather(city)
```

Typed handlers may receive `McpContext`, `McpCancellation`,
`McpProgressReporter`, or `McpLogger` parameters, and may return a `Future[T]`,
`McpToolResult`, or typed `McpResult[T]`. Use `mcpResult(value)` for success and
`mcpResultError[T](code, message, details)` for typed failures. `Option`, enums,
objects, sequences, tables, and nested combinations are supported. Pass `inputSchema = ...` or
`outputSchema = ...` to override inference when a wire schema needs more
detail. `mcpJsonSchema(MyType)` is available when a schema needs to be reused.
Use `-d:mcpwireDebugMacros` to print the generated registration code.

The low-level protocol envelope is `McpWireResult`; typed tool handlers should
use `McpResult[T]` or `McpToolResult`.

`McpStateStore` provides expiring, subject-bound opaque handles when a workflow
needs to carry state across otherwise stateless requests.

Use `server.setObservability` to attach optional request logging, metrics, and
span hooks. Each `McpRequestEvent` includes the method, separate correlation
ID, transport, trace context, duration, request/response bytes, result or
error code, cancellation state, and active subscription count. Hooks are
library-free; `context.log` treats request `logLevel` metadata as the minimum
level to emit and defaults to `info`. Request content and results are not
included in events.

Resources use typed text or base64-encoded blob contents:

```nim
server.addResource newMcpResource("memo://today", "Today's memo",
  resourceText("memo://today", "Ship it", "text/plain"))

server.addResource newFileResource(getCurrentDir(), "README.md",
  uriValue = "file:///project/README.md", mimeType = "text/markdown")
```

`mcpResource`, `mcpResourceTemplate`, `mcpPrompt`, and `mcpCompletion` provide
the same concise declaration style for the other features. Use
`newMcpResourceTemplate` for parameterized resources and
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

Handlers can call `context.checkCancelled()` and `context.reportProgress(...)`.
When request metadata contains `progressToken`, progress is emitted as a wire
notification through the transport's notification sender. Set
`server.setToolTimeout` for a per-tool deadline and call `server.cancelRequest`
or `server.cancelActiveRequests` during shutdown. HTTP adapters should call
`request.cancellation.cancel("client disconnected")` when their framework
reports a closed request stream.

Compose tool middleware with `server.use`. Built-ins include
`mcpAuthMiddleware`, `mcpValidationMiddleware`, `mcpTimingMiddleware`,
`mcpRetryMiddleware`, `mcpPolicyMiddleware`, and `mcpApprovalMiddleware`.
Use `newMcpToolGroup`, `addToolGroup`, or `addTools(namespace, tools)` for
grouped registration. Discovery is sorted by final tool name regardless of
registration order.

Use the transport-neutral peer for clients or composition:

```nim
let upstream = newMcpServer("upstream", "1.0.0")
let local = newMcpServer("local", "1.0.0")
discard local.mountMcpServer(newMcpInProcessTransport(upstream), "upstream")
```

`McpMessageTransport` carries typed JSON-RPC messages and has no server or
transport dependency, so nimgent can adapt stdio, HTTP, or another client
implementation to it. `mountMcpServer` discovers paginated tools, resources,
templates, prompts, and completions, then exposes them as namespaced local
features. Tool, prompt, resource, and URI-template collisions are rejected
before registration; resource URIs are encoded under the namespace.

Enable long-running tools with `server.enableTasks()` and
`newMcpTaskTool`. The server advertises `io.modelcontextprotocol/tasks` only
when enabled, requires that capability on each task-augmented request, returns
`resultType: "task"`, and exposes `tasks/get`, `tasks/update`, and
`tasks/cancel`. The default in-memory store uses unguessable, expiring,
principal-scoped handles; `newMcpTaskStoreBackend` supplies durable storage
callbacks. Task handlers may return `complete` or `input_required`, and task
poll results include progress, pending input, or the final result/error.

Register other extensions with `newMcpExtension`, `server.registerExtension`,
and `server.finalizeExtension`. Draft extensions are neither advertised nor
dispatched. Finalized extensions contribute capabilities, metadata, methods,
schemas, and transport rules, while unknown client extension capability fields
remain available for proxying and composition.

Remote HTTP authorization is opt-in. Pass an `McpAuthorizationConfig` to
`newMcpHttpConfig`; its verifier receives the bearer token and resource and
returns validated claims. Protected-resource metadata is served from
`/.well-known/oauth-protected-resource/<endpoint>`. Use
`server.setToolFilter`, `setResourceFilter`, and `setPromptFilter` for
principal-based visibility. See [examples/auth_server.nim](examples/auth_server.nim)
and [SECURITY.md](SECURITY.md) before exposing a server publicly.

## License

MIT. See [LICENSE](LICENSE).
