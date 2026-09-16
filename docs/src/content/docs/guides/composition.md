---
title: Composition
description: Mount another MCP server's tools, resources, and prompts under a namespace.
---

Use composition when one Nim server should expose features owned by another MCP server. The upstream can be in the same process or behind any transport that implements `McpMessageTransport`.

## Mount an in-process server

```nim
import std/json
import nimwire

let upstream = mcpServer("upstream", "1.0.0"):
  server.addTool mcpTool("echo", "Echo from upstream", %*{"type": "object"},
    proc (args: JsonNode, context: McpContext): McpToolResult =
      textResult("served by upstream"))

let local = mcpServer("local", "1.0.0"):
  discard

discard local.mountMcpServer(
  newMcpInProcessTransport(upstream),
  "upstream")
```

The mount performs discovery, follows paginated lists, and registers the upstream's tools, resources, resource templates, prompts, and completions. A tool called `search` is exposed locally as `upstream.search`.

For async applications, use `mountMcpServerAsync` and await the returned `McpProxy`.

## Namespaces and collisions

The namespace must be a valid tool-name segment. Tools and prompts receive the namespace as a prefix. Remote resource URIs are encoded into a local `urn:nimwire:proxy:` URI so they cannot collide with local URIs.

nimwire checks every discovered feature before changing the local registry. If a tool name, resource URI, resource template, or prompt name collides, the mount fails instead of partially registering the remote set.

## Use a transport-neutral peer

`McpPeer` creates requests with the protocol version, client information, and client capabilities in `_meta`:

```nim
let peer = newMcpInProcessPeer(upstream)
let response = peer.request("tools/list")
echo response.resultType
peer.close()
```

This same peer helper works with a custom `McpMessageTransport`. The transport receives already validated JSON-RPC values, so adapting a remote client does not require coupling it to `McpServer`.

## Remote behavior

Mounted tools forward arguments and preserve remote content, structured content, and error flags. Mounted prompts forward prompt arguments and messages. Mounted resources fetch their contents when the local client reads the proxy URI. Completions are forwarded when the upstream advertises completion capability.

Related: [Transports](/guides/transports/) and the [composition API reference](/reference/api/nimwire/composition/).
