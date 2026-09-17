---
title: Core API
description: The main nimwire types, modules, and entry points.
---

Most applications can import `nimwire` and use the complete public API. Focused imports are available when you want a smaller dependency surface.

## Start here

| Entry point | Use it for |
| --- | --- |
| `newMcpServer` | Create a server registry |
| `mcpServer` | Declare and register a server in one block |
| `mcpTool` and `server.tool` | Register raw or typed tools |
| `server.addResource` | Publish static or generated resources |
| `server.addPrompt` | Publish prompts and arguments |
| `serveStdio` | Run a newline-delimited stdio server |
| `newMcpHttpServer` | Run the stdlib Streamable HTTP adapter |
| `newMcpWebSocketServer` | Run the stdlib WebSocket adapter |
| `handleHttpRequest` | Adapt HTTP in another web framework |
| `handleMessageAsync` | Dispatch already-parsed JSON-RPC in a custom transport |
| `newMcpInProcessPeer` | Send requests without a process or socket |

## Public modules

| Module | Covers |
| --- | --- |
| `nimwire/core` | JSON-RPC values, MCP results, content, and errors |
| `nimwire/server` | Server registration, discovery, dispatch, filters, and timeouts |
| `nimwire/schema` | JSON Schema validation and compile-time type derivation |
| `nimwire/resources` | Resources, URI templates, files, and contents |
| `nimwire/prompts` | Prompt messages, arguments, and completions |
| `nimwire/context` | Request metadata, principals, cancellation, progress, and state handles |
| `nimwire/transports/stdio` | Stdio framing and serving |
| `nimwire/transports/http` | Streamable HTTP request handling and stdlib server |
| `nimwire/transports/websocket` | WebSocket transport and stdlib server |
| `nimwire/transport` | Typed message transports and `McpPeer` |
| `nimwire/transports/inproc` | Linked in-process transports |
| `nimwire/auth` | Bearer authorization and protected-resource metadata |
| `nimwire/security` | Limits, URL checks, and redaction |
| `nimwire/observability` | Request logs, metrics, and span hooks |
| `nimwire/middleware` | Tool authorization, policy, timing, retries, and approval |
| `nimwire/composition` | Mount remote features under a namespace |
| `nimwire/tasks` | Opt-in long-running MCP Tasks |
| `nimwire/extensions` | Finalized custom extension methods |
| `nimwire/subscriptions` | In-process change event delivery |
| `nimwire/mrtr` | Multi-round-trip input handling |
| `nimwire/testing` | Request helpers for tests |

## Protocol boundary

nimwire targets MCP revision `2026-07-28` and JSON-RPC `2.0`. The built-in server dispatches `server/discover`, `ping`, tool, resource, prompt, completion, subscription, and finalized extension methods. Unknown methods return `mcpMethodNotFoundCode`.

The parser defaults to a 1 MiB message limit and 64 levels of nesting. Stdio and HTTP transports let you configure their limits, and `McpSecurityLimits` adds application-level bounds.

For every exported type and procedure, see the [generated API reference](/reference/api/nimwire/). Start with [Quickstart](/guides/quickstart/) for a complete server.
