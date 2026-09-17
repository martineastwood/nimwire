---
title: Tasks
description: Run long-lived MCP tools with polling, input, and cancellation.
---

MCP Tasks are opt-in. Enable them when a tool may outlive the original request and the client needs a task handle to poll or cancel.

## Enable Tasks

```nim
import std/[asyncdispatch, json]
import nimwire

let server = newMcpServer("worker", "1.0.0")
server.enableTasks()
```

`enableTasks()` installs the `io.modelcontextprotocol/tasks` extension and the default in-memory store. The server advertises the extension only after it is enabled. A client must advertise the same extension capability before it can call a task tool.

## Register a task tool

```nim
let rebuild = newMcpTaskTool("rebuild", "Rebuild the search index", %*{
  "type": "object"
}, proc (arguments: JsonNode,
        context: McpContext): Future[McpWireResult] {.async.} =
  for step in 1 .. 3:
    context.checkCancelled()
    await sleepAsync(100)
    await context.reportProgress(step.float, 3, "Indexing")
  newMcpResult(mcpComplete, %*{
    "content": [{"type": "text", "text": "Index rebuilt"}]
  }))

server.addTool rebuild
server.serveStdio()
```

Task handlers return `mcpComplete` for a final result or `mcpInputRequired` when they need client input. See [Multi-round-trip input](/guides/mrtr/) for elicitation and retry patterns. They must not return another `mcpTask` result.

The initial `tools/call` response has `resultType: "task"` and includes a task ID, status, timestamps, expiry information, and a suggested poll interval. Progress updates are stored on the task.

## Poll and control a task

The extension adds:

- `tasks/get` to read status and the final result;
- `tasks/update` to provide pending `inputResponses`; and
- `tasks/cancel` to stop a working task.

The default store uses unguessable, expiring, principal-scoped handles. A task created by one authenticated subject cannot be read or cancelled by another subject. Unauthenticated tasks use the empty subject, so protect the endpoint if task ownership matters.

## Use durable storage

Provide `create`, `get`, and `update` callbacks with `newMcpTaskStoreBackend` when task records need external persistence. The callbacks own persistence. Keep the task owner, expiry, status, input requests, result, and error fields together so the same subject and expiry checks can be applied on reads. Handler execution and pending runtime state still belong to the current process, so define restart behavior for active tasks separately.

```nim
let store = newMcpTaskStoreBackend(
  proc (task: McpTask) = saveTask(task),
  proc (taskId, subject: string): McpTask = loadTask(taskId, subject),
  proc (task: McpTask) = updateTask(task),
  ttlMs = 60 * 60 * 1000)

server.enableTasks(store)
```

Related: [Request context](/guides/context/) for cancellation and input, and the [tasks API reference](/reference/api/nimwire/tasks/).
