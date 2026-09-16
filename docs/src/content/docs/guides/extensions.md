---
title: Extensions
description: Register finalized, schema-validated MCP extension methods.
---

Use extensions for MCP methods that are not one of the built-in tools, resources, prompts, or transport operations. Extension names must be fully qualified, for example `example.com/telemetry`.

## Register an extension

```nim
import std/[asyncdispatch, json]
import nimwire

let server = newMcpServer("extensions", "1.0.0")
let extension = newMcpExtension(
  "example.com/echo",
  capabilities = %*{"enabled": true},
  metadata = %*{"example.com/echo": {"version": 1}})

extension.addExtensionMethod(
  "example/echo",
  proc (params: JsonNode,
        context: McpContext): Future[McpWireResult] {.async.} =
    newMcpResult(mcpComplete, %*{"value": params["value"]}),
  inputSchema = %*{
    "type": "object",
    "properties": {"value": {"type": "string"}},
    "required": ["value"],
    "additionalProperties": false
  })

server.registerExtension(extension)
server.finalizeExtension("example.com/echo")
```

Only finalized extensions are advertised in discovery and dispatched. Finalize after all methods and schemas have been added.

## Client capabilities

Set `requiresClientCapability = true` when the extension must be explicitly supported by the client:

```nim
let extension = newMcpExtension(
  "example.com/approval",
  requiresClientCapability = true)
```

Calls fail with `mcpMissingRequiredClientCapabilityCode` until the request metadata contains that extension capability. This is also how the built-in Tasks extension protects its methods.

`inputSchema` and `outputSchema` are validated at registration and dispatch boundaries. `transportRules` and method metadata are retained for the extension's wire contract.

Related: [Tasks](/guides/tasks/) and the [extensions API reference](/reference/api/nimwire/extensions/).
