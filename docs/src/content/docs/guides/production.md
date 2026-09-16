---
title: Production controls
description: Add middleware, observability, retries, deadlines, and cache hints.
---

The core server is usable without a telemetry or web framework dependency. Add only the hooks your application needs.

## Add tool middleware

Middleware wraps tool calls in registration order:

```nim
import nimwire

let server = newMcpServer("production", "1.0.0")

server.use mcpAuthMiddleware(proc (name: string,
    principal: McpPrincipal): bool =
  not principal.isNil and "tools:read" in principal.scopes)

server.use mcpTimingMiddleware(proc (name: string,
    durationMs: float) =
  echo name, " took ", durationMs, " ms")
```

Built-ins include:

- `mcpAuthMiddleware` for a principal check;
- `mcpValidationMiddleware` for application validation;
- `mcpTimingMiddleware` for per-tool duration;
- `mcpPolicyMiddleware` for a synchronous policy;
- `mcpApprovalMiddleware` for sync or async approval; and
- `mcpRetryMiddleware` for retryable failures.

Use `server.use(@[...])` when registering a list of middleware. A middleware calls `await next()` to continue the call and can return its own `McpToolResult` instead.

## Retry only safe failures

Mark a typed failure retryable when repeating the operation is safe:

```nim
import std/json

mcpResultError[JsonNode]("upstream_busy", "Try again", retryable = true)
```

For raised errors, use `retryableMcpError`. Then add the retry middleware:

```nim
server.use mcpRetryMiddleware(maxAttempts = 3, delayMs = 100)
```

The default predicate retries only `McpError` values marked retryable. Pass `retryOn` for an application-specific predicate.

## Observe requests

```nim
import std/json

server.setObservability McpObservability(
  requestLog: proc (event: McpRequestEvent) =
    echo $toJson(event),
  metrics: proc (event: McpRequestEvent) =
    discard event)
```

Each event includes a correlation ID, request ID, method, transport, duration, request and response byte counts, result type or error code, cancellation state, active subscription count, and optional trace context or log level. Request content and tool arguments are not included.

Use `spanStart` and `spanEnd` when an application already owns tracing. `McpSpanHandle.state` is opaque application state returned by the start hook.

## Bound time and concurrency

Use `setToolTimeout` for per-tool deadlines and the HTTP `requestTimeoutMs` for an endpoint-wide deadline. `maxConcurrentCalls` limits active server dispatch, while `maxConcurrentRequests` limits the stdlib HTTP adapter before a request reaches dispatch.

When shutting down, call `cancelActiveRequests` and `closeSubscriptions`, or call `McpHttpServer.shutdown()` for the built-in adapter.

## Cache discovery results

Set `listTtlMs` and `listCacheScope` on `newMcpServer` to add cache hints to list responses and resource reads:

```nim
let server = newMcpServer(
  "catalog", "1.0.0",
  listTtlMs = 30_000,
  listCacheScope = "private",
  listPageSize = 50)
```

Use `"public"` only when the result is safe to share between callers. Principal-based filters normally require `"private"`.

Related: [Security](/guides/security/), [Request context](/guides/context/), and [Subscriptions](/guides/subscriptions/).
