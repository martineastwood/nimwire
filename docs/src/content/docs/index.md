---
title: nimwire
description: Build MCP servers and backends in Nim.
---

nimwire provides the Niminal stack's primitives for building Model Context
Protocol servers and backends in Nim, including typed resources, prompts,
completion, subscriptions, multi-round-trip input handling, cooperative
cancellation/progress, opt-in MCP Tasks, generic extensions, HTTP authorization
hooks, URI templates, binary contents, confined file helpers, and optional
request observability hooks.

`server.setObservability` exposes structured request events for logs and
metrics plus library-free span start/end hooks. Events carry a separate
correlation ID, request method and JSON-RPC ID, trace context, duration,
request/response bytes, result or error code, cancellation state, and active
subscription count. Request `logLevel` metadata is treated as the minimum
level for `context.log`; the default is `info`.

See the repository [security checklist](https://github.com/martineastwood/nimwire/blob/main/SECURITY.md)
and the [authorization example](https://github.com/martineastwood/nimwire/blob/main/examples/auth_server.nim)
before deploying a remote server.

Call `server.enableTasks()` and register `newMcpTaskTool` for long-running
work. Tasks return `resultType: "task"`, can be polled with `tasks/get`,
updated with `tasks/update`, and cancelled with `tasks/cancel`; use
`newMcpTaskStoreBackend` for durable persistence. Generic extensions are
registered with `newMcpExtension`, then advertised and dispatched after
`server.finalizeExtension`.

[View nimwire on GitHub](https://github.com/martineastwood/nimwire)
