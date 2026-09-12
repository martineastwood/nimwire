## In-process change notification bus for modern MCP subscriptions.

import std/[asyncdispatch, json]

import ./core

type
  McpSubscriptionEventKind* = enum
    mcpToolsListChanged
    mcpPromptsListChanged
    mcpResourcesListChanged
    mcpResourceUpdated

  McpSubscriptionFilter* = object
    toolsListChanged*: bool
    promptsListChanged*: bool
    resourcesListChanged*: bool
    resourceSubscriptions*: seq[string]

  McpSubscriptionEvent* = object
    kind*: McpSubscriptionEventKind
    uri*: string

  McpSubscriptionMessageHandler* = proc (message: JsonNode) {.closure.}
  McpEventPublisher* = proc (event: McpSubscriptionEvent) {.closure.}
  McpSubscriptionCloseHandler* = proc (subscription: McpSubscription,
                                        graceful: bool) {.closure.}

  McpSubscription* = ref object
    id*: McpId
    filter*: McpSubscriptionFilter
    active*: bool
    ready: bool
    handler: McpSubscriptionMessageHandler
    closeHandler: McpSubscriptionCloseHandler
    bus: McpEventBus
    closed: Future[void]

  McpEventBus* = ref object
    subscriptions: seq[McpSubscription]
    publisher: McpEventPublisher

proc newMcpEventBus*(publisher: McpEventPublisher = nil): McpEventBus =
  McpEventBus(publisher: publisher)

proc sameId(left, right: McpId): bool =
  $toJson(left) == $toJson(right)

proc subscribe*(bus: McpEventBus, id: McpId,
                filter: McpSubscriptionFilter,
                handler: McpSubscriptionMessageHandler): McpSubscription =
  if bus.isNil: raise newMcpError("event bus must not be nil")
  if id.kind == mcpNullId:
    raise newMcpError("subscription id must not be null")
  if handler.isNil:
    raise newMcpError("subscription handler must not be nil")
  for current in bus.subscriptions:
    if current.active and current.id.sameId(id):
      raise newMcpError("duplicate subscription id")
  result = McpSubscription(id: id, filter: filter, active: true,
    handler: handler, bus: bus,
    closed: newFuture[void]("mcpSubscription"))
  bus.subscriptions.add result

proc activate*(subscription: McpSubscription) =
  if not subscription.isNil and subscription.active:
    subscription.ready = true

proc unsubscribe*(bus: McpEventBus, subscription: McpSubscription): bool =
  if bus.isNil or subscription.isNil: return false
  for index in countdown(bus.subscriptions.high, 0):
    if bus.subscriptions[index] == subscription:
      bus.subscriptions[index].active = false
      bus.subscriptions[index].ready = false
      if not bus.subscriptions[index].closed.finished:
        bus.subscriptions[index].closed.complete()
      bus.subscriptions.delete(index)
      return true
  false

proc setCloseHandler*(subscription: McpSubscription,
                      handler: McpSubscriptionCloseHandler) =
  if not subscription.isNil:
    subscription.closeHandler = handler

proc close*(subscription: McpSubscription, graceful = true) =
  if not subscription.isNil:
    if not subscription.closeHandler.isNil:
      subscription.closeHandler(subscription, graceful)
    else:
      discard subscription.bus.unsubscribe(subscription)

proc isActive*(subscription: McpSubscription): bool =
  not subscription.isNil and subscription.active

proc waitClosed*(subscription: McpSubscription): Future[void] =
  if subscription.isNil:
    raise newMcpError("subscription must not be nil")
  subscription.closed

proc subscriptionMethod(event: McpSubscriptionEventKind): string =
  case event
  of mcpToolsListChanged: "notifications/tools/list_changed"
  of mcpPromptsListChanged: "notifications/prompts/list_changed"
  of mcpResourcesListChanged: "notifications/resources/list_changed"
  of mcpResourceUpdated: "notifications/resources/updated"

proc subscriptionMatches(filter: McpSubscriptionFilter,
                         event: McpSubscriptionEvent): bool =
  case event.kind
  of mcpToolsListChanged: filter.toolsListChanged
  of mcpPromptsListChanged: filter.promptsListChanged
  of mcpResourcesListChanged: filter.resourcesListChanged
  of mcpResourceUpdated: event.uri in filter.resourceSubscriptions

proc notification*(subscription: McpSubscription,
                   event: McpSubscriptionEvent): JsonNode =
  var params = newJObject()
  params["_meta"] = newJObject()
  params["_meta"]["io.modelcontextprotocol/subscriptionId"] =
    toJson(subscription.id)
  if event.kind == mcpResourceUpdated:
    params["uri"] = %event.uri
  %*{"jsonrpc": mcpJsonRpcVersion,
    "method": event.kind.subscriptionMethod, "params": params}

proc deliver*(subscription: McpSubscription, message: JsonNode) =
  if subscription.isNil or not subscription.active or subscription.handler.isNil:
    return
  try:
    subscription.handler(message)
  except CatchableError:
    discard

proc publish*(bus: McpEventBus, event: McpSubscriptionEvent) =
  if bus.isNil: return
  if not bus.publisher.isNil:
    try:
      bus.publisher(event)
    except CatchableError:
      discard
  let subscriptions = bus.subscriptions
  for subscription in subscriptions:
    if not subscription.active or not subscription.ready or
        not subscription.filter.subscriptionMatches(event):
      continue
    subscription.deliver(subscription.notification(event))

proc publishToolsChanged*(bus: McpEventBus) =
  bus.publish(McpSubscriptionEvent(kind: mcpToolsListChanged))

proc publishPromptsChanged*(bus: McpEventBus) =
  bus.publish(McpSubscriptionEvent(kind: mcpPromptsListChanged))

proc publishResourcesChanged*(bus: McpEventBus) =
  bus.publish(McpSubscriptionEvent(kind: mcpResourcesListChanged))

proc publishResourceUpdated*(bus: McpEventBus, uri: string) =
  bus.publish(McpSubscriptionEvent(kind: mcpResourceUpdated, uri: uri))
