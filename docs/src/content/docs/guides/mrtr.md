---
title: Multi-round-trip input
description: Ask for confirmation, sampling, or roots before completing a tool, prompt, or resource call.
---

Some MCP flows need more than one round trip. A tool might ask the user to confirm an action, a prompt might need a model sample, or a resource read might need the client's workspace roots. nimwire models these as `input_required` results with no server-side session.

## Return input_required from a handler

Build one or more input requests, then install them on the context:

```nim
import std/json
import nimwire

let confirmation = newMcpElicitationFormRequest(
  "Allow this operation?",
  %*{
    "type": "object",
    "properties": {"confirmed": {"type": "boolean"}},
    "required": ["confirmed"],
    "additionalProperties": false
  })

server.addTool mcpTool("dangerous", "Run a guarded operation", %*{
  "type": "object"
}, proc (args: JsonNode, context: McpContext): McpToolResult =
  if context.inputResponse("confirmation").isNil:
    context.requireInput(newMcpInputRequiredResult([
      ("confirmation", confirmation)]))
    return textResult("")
  let confirmed = context.inputResponse("confirmation")["content"]["confirmed"].getBool
  if not confirmed:
    return textResult("Operation declined", isError = true)
  textResult("Operation allowed"))
```

The first response has `resultType: "input_required"` and includes an `inputRequests` object keyed by the names you chose. The client answers on the next request with matching `inputResponses` and, when you returned one, the same `requestState`.

You can use the same pattern from prompt and resource handlers. Supported input methods are `elicitation/create`, `sampling/createMessage`, and `roots/list`.

## Form and URL elicitation

Form elicitation collects structured JSON from the user:

```nim
let form = newMcpElicitationFormRequest("Enter a display name", %*{
  "type": "object",
  "properties": {"name": {"type": "string", "minLength": 1}},
  "required": ["name"],
  "additionalProperties": false
})
```

URL elicitation sends the user to a safe HTTPS page instead. nimwire validates the URL with the same rules as other MCP links:

```nim
let urlPrompt = newMcpElicitationUrlRequest(
  "Sign in to continue",
  "https://auth.example.com/consent")
```

Build a full `input_required` result with `newMcpInputRequiredResult`. Pass a `requestState` string when the next request must carry opaque state.

## Seal and verify request state

When `requestState` must be tamper-evident, configure sealing on the server:

```nim
let server = newMcpServer(
  "stateful", "1.0.0",
  requestStateSealer = proc (payload: JsonNode, context: McpContext): string =
    "sealed:" & payload["step"].getStr,
  requestStateVerifier = proc (state: string, context: McpContext): JsonNode =
    if state == "sealed:1": %*{"step": "1"} else: nil)
```

Inside a handler, call `context.sealRequestState(payload)` before returning `input_required`. On the retry request, read the verified payload from `context.requestStatePayload`.

For short-lived application data that is not part of the wire contract, use `newMcpStateStore` and opaque handles instead. See [Request context](/guides/context/).

## Retry from a custom client

`McpInputClient` helps MCP clients and proxies answer pending input requests and mint a fresh JSON-RPC ID for each retry:

```nim
import nimwire

let client = newMcpInputClient(
  elicitationHandler = proc (request: McpElicitationRequest): McpElicitationResult =
    acceptElicitation(%*{"confirmed": true}))

let retry = client.retryInputRequired(originalRequest, inputRequiredResponse)
```

Configure `setSamplingHandler` and `setRootsHandler` when the pending input uses those methods. The client validates elicitation responses, preserves `requestState` from the server result, and rejects reused request IDs.

Related: [Request context](/guides/context/), [Tasks](/guides/tasks/) for long-running work that outlives a single call, and the [MRTR API reference](/reference/api/nimwire/mrtr/).
