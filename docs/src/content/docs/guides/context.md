---
title: Request context
description: Handle cancellation, progress, deadlines, principals, and multi-round-trip input.
---

Each request gets an `McpContext`. Pass it through application calls that need request metadata, cancellation, authorization, or notifications. Do not share a context between requests.

## Check cancellation

Long-running handlers should check for cancellation at useful boundaries:

```nim
import std/[asyncdispatch, json]
import nimwire

let server = newMcpServer("context", "1.0.0")

let slow: McpToolHandler = proc (
    arguments: JsonNode,
    context: McpContext): Future[McpToolResult] {.async.} =
  for step in 1 .. 10:
    context.checkCancelled()
    await sleepAsync(100)
  textResult("finished")

server.addTool newMcpTool("slow", "Run a cancellable operation",
  %*{"type": "object"}, slow)
server.setToolTimeout("slow", 5000)
```

`setToolTimeout` sets a per-tool deadline in milliseconds. The context also exposes `remainingTimeMs()`. The server can cancel one request with `cancelRequest(id)` or all active requests with `cancelActiveRequests()`.

## Report progress

Call `reportProgress` with an increasing value. When the client supplied a `progressToken`, nimwire emits `notifications/progress` through the transport:

```nim
await context.reportProgress(1, 3, "Reading files")
await context.reportProgress(2, 3, "Indexing files")
await context.reportProgress(3, 3, "Done")
```

Progress values must be non-negative. When `total` is set, progress cannot exceed it. A later progress value must be greater than the previous one.

## Use request metadata

`context.metadata` contains the protocol version, client information, client capabilities, trace context, requested log level, and progress token. `context.transport` identifies stdio, HTTP, or in-process delivery. `context.principal` is populated by HTTP authorization or by the framework adapter.

Use `context.log(level, message)` for request-scoped logs. The client's `logLevel` metadata is treated as the minimum level. A logger must be supplied by the transport or framework adapter.

## Ask for more input

Tools, prompts, and resources can return `input_required` without keeping a server session alive. Build an input request and install it on the context:

```nim
let confirmation = newMcpElicitationFormRequest(
  "Allow this operation?",
  %*{
    "type": "object",
    "properties": {"confirmed": {"type": "boolean"}},
    "required": ["confirmed"],
    "additionalProperties": false
  })

if context.inputResponse("confirmation").isNil:
  context.requireInput(newMcpInputRequiredResult([
    ("confirmation", confirmation)]))
  return textResult("")

let response = context.inputResponse("confirmation")
```

On the next request, the client sends `inputResponses` and can include the returned `requestState`. Configure `requestStateSealer` and `requestStateVerifier` on `newMcpServer` when that state must be authenticated. The library does not invent a server-side session for this flow.

`McpInputClient` helps a custom client answer `elicitation/create`, `sampling/createMessage`, or `roots/list` requests and create a fresh JSON-RPC ID for each retry. See the [MRTR API reference](/reference/api/nimwire/mrtr/).

## Carry application state safely

`newMcpStateStore` creates expiring, subject-bound opaque handles:

```nim
let states = newMcpStateStore(ttlSeconds = 900, maxEntries = 1000)
let handle = states.mintStateHandle("user-42", %*{"step": 2})
let claim = states.verifyStateHandle(handle, "user-42")
```

You can attach the store to a context through the transport adapter. A handle made for one principal does not verify for another principal.

Related: [Tasks](/guides/tasks/) for durable long-running work and [Security](/guides/security/) for principal setup.
