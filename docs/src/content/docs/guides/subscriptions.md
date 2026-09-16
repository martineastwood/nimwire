---
title: Subscriptions
description: Send live tool, prompt, and resource changes to connected clients.
---

Subscriptions are opt-in change streams. They are useful when a client should refresh discovery or a resource after the application changes.

## Publish changes

Mark the capabilities that may change, then publish the corresponding event:

```nim
import nimwire

let server = newMcpServer("catalog", "1.0.0")

server.markToolsChanged()
server.markPromptsChanged()
server.markResourcesChanged()
server.markResourceUpdated("memo://today")
```

The first three calls also make the matching list-changed capability visible during discovery. Use `markResourceUpdated` for the contents of one URI.

## Handle a subscription in a custom adapter

```nim
var messages: seq[JsonNode]
let subscription = server.openSubscription(
  McpId(kind: mcpIntegerId, integerValue: 1),
  McpSubscriptionFilter(
    toolsListChanged: true,
    resourceSubscriptions: @["memo://today"]),
  proc (message: JsonNode) = messages.add message)

server.markToolsChanged()
server.markResourceUpdated("memo://today")
subscription.close()
```

The handler receives an acknowledgment first, then matching JSON-RPC notifications. A resource subscription matches only the exact URI supplied in the filter.

The filter can include `toolsListChanged`, `promptsListChanged`, `resourcesListChanged`, and `resourceSubscriptions`. Resource subscription values must be non-empty valid URIs; duplicate values are ignored.

## Stream subscriptions over HTTP

The HTTP adapter keeps a `subscriptions/listen` request open when its request has a `streamWriter`. The stdlib adapter creates that writer for you. Set `preferSse = true` when the adapter should use `text/event-stream` responses for streamed messages.

When a client disconnects, cancel its request and close the subscription. `McpHttpServer.shutdown()` closes all active subscriptions during server shutdown.

## Close gracefully

Use `subscription.close()` or `server.closeSubscription(subscription)`. A graceful close sends a final complete response with the subscription ID. Pass `graceful = false` when the connection is already gone. `cancelSubscription(id)` is the direct form for a request or subscription ID.

You can supply a publisher to `newMcpEventBus` when the application also needs an in-process event feed:

```nim
let bus = newMcpEventBus(proc (event: McpSubscriptionEvent) =
  echo event.kind)
let server = newMcpServer("catalog", "1.0.0", eventBus = bus)
```

Related: [Production controls](/guides/production/) and the [subscriptions API reference](/reference/api/nimwire/subscriptions/).
