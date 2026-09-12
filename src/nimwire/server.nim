## MCP server registry and typed feature dispatch.

import std/[algorithm, asyncdispatch, base64, json, macros, options, strutils]

import ./core
import ./context
import ./prompts
import ./resources
import ./schema
import ./subscriptions

type
  McpToolHandler* = proc (arguments: JsonNode,
                          context: McpContext): Future[McpToolResult] {.closure.}
  McpSyncToolHandler* = proc (arguments: JsonNode,
                              context: McpContext): McpToolResult {.closure.}
  McpResourceNotificationHandler* = proc (message: JsonNode) {.closure.}

  McpResourceSubscription* = ref object
    id*: McpId
    resourcesListChanged*: bool
    resourceUris*: seq[string]
    handler: McpResourceNotificationHandler

  McpTool* = object
    name: string
    description: string
    inputSchema: JsonNode
    outputSchema: JsonNode
    title: string
    icons: JsonNode
    annotations: JsonNode
    handler: McpToolHandler
    headerBindings: seq[McpHeaderBinding]

  McpServer* = ref object
    name: string
    version: string
    instructions: string
    listTtlMs: int
    listCacheScope: string
    listPageSize: int
    toolsListChanged: bool
    tools: seq[McpTool]
    resourcesListChanged: bool
    resourcesSubscribe: bool
    resources: seq[McpResource]
    resourceTemplates: seq[McpResourceTemplate]
    resourceSubscriptions: seq[McpResourceSubscription]
    promptsListChanged: bool
    prompts: seq[McpPrompt]
    eventBus: McpEventBus
    subscriptions: seq[McpSubscription]
    requestStateSealer: McpRequestStateSealer
    requestStateVerifier: McpRequestStateVerifier

proc newMcpServer*(name, version: string, instructions = "",
                   listTtlMs = 0, listCacheScope = "private",
                   listPageSize = 0, eventBus: McpEventBus = nil,
                   requestStateSealer: McpRequestStateSealer = nil,
                   requestStateVerifier: McpRequestStateVerifier = nil): McpServer =
  if name.len == 0: raise newMcpError("server name must not be empty")
  if version.len == 0: raise newMcpError("server version must not be empty")
  if listTtlMs < 0: raise newMcpError("listTtlMs must be at least 0")
  if listCacheScope notin ["public", "private"]:
    raise newMcpError("listCacheScope must be public or private")
  if listPageSize < 0: raise newMcpError("listPageSize must be at least 0")
  McpServer(name: name, version: version, instructions: instructions,
    listTtlMs: listTtlMs, listCacheScope: listCacheScope,
    listPageSize: listPageSize,
    eventBus: if eventBus.isNil: newMcpEventBus() else: eventBus,
    requestStateSealer: requestStateSealer,
    requestStateVerifier: requestStateVerifier)

proc resultObject(server: McpServer): McpResult
proc closeSubscription*(server: McpServer, subscription: McpSubscription,
                        graceful = true): bool

proc validateToolDefinition(name, description: string, inputSchema,
                            outputSchema, icons, annotations: JsonNode):
    seq[McpHeaderBinding] =
  validateToolName(name)
  if description.len == 0: raise newMcpError("tool description must not be empty")
  result = mcpHeaderBindings(inputSchema)
  if not outputSchema.isNil:
    discard requireJsonSchema(outputSchema, "tool outputSchema")
  validateToolPresentation(icons, annotations)

proc newMcpTool*(name, description: string, inputSchema: JsonNode,
                 handler: McpToolHandler,
                 outputSchema: JsonNode = nil, title = "",
                 icons: JsonNode = nil, annotations: JsonNode = nil): McpTool =
  let headerBindings = validateToolDefinition(name, description, inputSchema,
    outputSchema, icons, annotations)
  if handler.isNil: raise newMcpError("tool handler must not be nil")
  McpTool(name: name, description: description, inputSchema: inputSchema,
    outputSchema: outputSchema, title: title, icons: icons,
    annotations: annotations, handler: handler, headerBindings: headerBindings)

proc newMcpTool*(name, description: string, inputSchema: JsonNode,
                 handler: McpSyncToolHandler,
                 outputSchema: JsonNode = nil, title = "",
                 icons: JsonNode = nil, annotations: JsonNode = nil): McpTool =
  if handler.isNil: raise newMcpError("tool handler must not be nil")
  newMcpTool(name, description, inputSchema,
    proc (arguments: JsonNode, context: McpContext): Future[McpToolResult] {.async.} =
      handler(arguments, context), outputSchema, title, icons, annotations)

template mcpTool*(name, description: string, inputSchema: JsonNode,
                  handler: untyped, outputSchema: JsonNode = nil,
                  title = "", icons: JsonNode = nil,
                  annotations: JsonNode = nil): McpTool =
  ## Concise tool declaration that works with sync or async handlers.
  newMcpTool(name, description, inputSchema, handler, outputSchema, title,
    icons, annotations)

macro mcpServer*(name, version: static[string], body: untyped): untyped =
  ## Build a server declaratively while keeping registration code local.
  let serverIdent = ident("server")
  result = quote do:
    block:
      var `serverIdent` = newMcpServer(`name`, `version`)
      `body`
      `serverIdent`

proc addTool*(server: McpServer, tool: McpTool) =
  if server.isNil: raise newMcpError("server must not be nil")
  for current in server.tools:
    if current.name == tool.name:
      raise newMcpError("duplicate tool name: " & tool.name)
  server.tools.add tool

proc resourceNotification(subscription: McpResourceSubscription,
                          methodName, uri: string): JsonNode =
  var params = newJObject()
  params["_meta"] = newJObject()
  params["_meta"]["io.modelcontextprotocol/subscriptionId"] =
    toJson(subscription.id)
  if uri.len > 0: params["uri"] = %uri
  %*{"jsonrpc": mcpJsonRpcVersion, "method": methodName,
    "params": params}

proc emitResourceListChanged(server: McpServer) =
  for subscription in server.resourceSubscriptions:
    if subscription.resourcesListChanged and not subscription.handler.isNil:
      try:
        subscription.handler(resourceNotification(subscription,
          "notifications/resources/list_changed", ""))
      except CatchableError:
        discard

proc emitResourceUpdated(server: McpServer, uri: string) =
  for subscription in server.resourceSubscriptions:
    if uri in subscription.resourceUris and not subscription.handler.isNil:
      try:
        subscription.handler(resourceNotification(subscription,
          "notifications/resources/updated", uri))
      except CatchableError:
        discard

proc subscribeResources*(server: McpServer, subscriptionId: McpId,
                         handler: McpResourceNotificationHandler,
                         resourcesListChanged = false,
                         resourceUris: seq[string] = @[]):
                         McpResourceSubscription =
  if server.isNil: raise newMcpError("server must not be nil")
  if subscriptionId.kind == mcpNullId:
    raise newMcpError("resource subscription id must not be null")
  if handler.isNil: raise newMcpError("resource subscription handler must not be nil")
  for uri in resourceUris:
    validateResourceUri(uri, "resource subscription")
  result = McpResourceSubscription(id: subscriptionId,
    resourcesListChanged: resourcesListChanged, resourceUris: resourceUris,
    handler: handler)
  server.resourceSubscriptions.add result
  server.resourcesSubscribe = true

proc unsubscribeResources*(server: McpServer,
                           subscription: McpResourceSubscription): bool =
  if server.isNil or subscription.isNil: return false
  for index in countdown(server.resourceSubscriptions.high, 0):
    if server.resourceSubscriptions[index] == subscription:
      server.resourceSubscriptions.delete(index)
      return true
  false

proc markResourcesChanged*(server: McpServer) =
  if server.isNil: raise newMcpError("server must not be nil")
  server.resourcesListChanged = true
  server.eventBus.publishResourcesChanged()
  server.emitResourceListChanged()

proc markResourceUpdated*(server: McpServer, uri: string) =
  if server.isNil: raise newMcpError("server must not be nil")
  validateResourceUri(uri, "resource")
  server.eventBus.publishResourceUpdated(uri)
  server.emitResourceUpdated(uri)

proc notifyResourceListChanged*(server: McpServer) =
  server.markResourcesChanged()

proc notifyResourceUpdated*(server: McpServer, uri: string) =
  server.markResourceUpdated(uri)

proc addResource*(server: McpServer, resource: McpResource) =
  if server.isNil: raise newMcpError("server must not be nil")
  validateResourceUri(resource.uri)
  if resource.name.len == 0:
    raise newMcpError("resource name must not be empty")
  if resource.size < -1:
    raise newMcpError("resource size must be non-negative")
  for content in resource.contents:
    discard resourceContentJson(content, resource.mimeType)
  for current in server.resources:
    if current.uri == resource.uri:
      raise newMcpError("duplicate resource URI: " & resource.uri)
  server.resources.add resource
  server.resourcesSubscribe = true

proc addResourceTemplate*(server: McpServer,
                          resourceTemplate: McpResourceTemplate) =
  if server.isNil: raise newMcpError("server must not be nil")
  validateUriTemplate(resourceTemplate.uriTemplate)
  if resourceTemplate.name.len == 0:
    raise newMcpError("resource template name must not be empty")
  for current in server.resourceTemplates:
    if current.uriTemplate == resourceTemplate.uriTemplate:
      raise newMcpError("duplicate resource URI template: " &
        resourceTemplate.uriTemplate)
  server.resourceTemplates.add resourceTemplate
  server.resourcesSubscribe = true

proc addResourceTemplateCompletion*(server: McpServer, uriTemplate,
                                    argument: string,
                                    handler: McpResourceCompletionHandler) =
  if server.isNil: raise newMcpError("server must not be nil")
  for index in 0 ..< server.resourceTemplates.len:
    if server.resourceTemplates[index].uriTemplate == uriTemplate:
      server.resourceTemplates[index].addCompletion(argument, handler)
      return
  raise newMcpError("unknown resource URI template: " & uriTemplate)

proc addResourceTemplateCompletion*(server: McpServer, uriTemplate,
                                    argument: string,
                                    handler: McpSyncResourceCompletionHandler) =
  if server.isNil: raise newMcpError("server must not be nil")
  for index in 0 ..< server.resourceTemplates.len:
    if server.resourceTemplates[index].uriTemplate == uriTemplate:
      server.resourceTemplates[index].addCompletion(argument, handler)
      return
  raise newMcpError("unknown resource URI template: " & uriTemplate)

proc findResource*(server: McpServer, uri: string): int =
  for index, resource in server.resources:
    if resource.uri == uri: return index
  -1

proc findResourceTemplate*(server: McpServer, uriTemplate: string): int =
  for index, resourceTemplate in server.resourceTemplates:
    if resourceTemplate.uriTemplate == uriTemplate: return index
  -1

proc addPrompt*(server: McpServer, prompt: McpPrompt) =
  if server.isNil: raise newMcpError("server must not be nil")
  if prompt.name.len == 0:
    raise newMcpError("prompt name must not be empty")
  for current in server.prompts:
    if current.name == prompt.name:
      raise newMcpError("duplicate prompt name: " & prompt.name)
  server.prompts.add prompt

proc findPrompt*(server: McpServer, name: string): int =
  for index, prompt in server.prompts:
    if prompt.name == name: return index
  -1

proc optionalBool(value: JsonNode, key, label: string): bool =
  if key notin value: return false
  if value[key].kind != JBool:
    raise newMcpError(label & " '" & key & "' must be a boolean")
  value[key].getBool

proc parseSubscriptionFilter*(value: JsonNode): McpSubscriptionFilter =
  let notifications = requireObject(value, "subscriptions/listen notifications")
  result.toolsListChanged = optionalBool(notifications, "toolsListChanged",
    "subscription notification")
  result.promptsListChanged = optionalBool(notifications, "promptsListChanged",
    "subscription notification")
  result.resourcesListChanged = optionalBool(notifications,
    "resourcesListChanged", "subscription notification")
  if "resourceSubscriptions" in notifications:
    if notifications["resourceSubscriptions"].kind != JArray:
      raise newMcpError("subscription notification 'resourceSubscriptions' must be an array")
    for value in notifications["resourceSubscriptions"].items:
      if value.kind != JString or value.getStr.len == 0:
        raise newMcpError("resource subscription URIs must be non-empty strings")
      validateResourceUri(value.getStr, "resource subscription")
      if value.getStr notin result.resourceSubscriptions:
        result.resourceSubscriptions.add value.getStr

proc acknowledgedFilter(server: McpServer,
                        requested: McpSubscriptionFilter): McpSubscriptionFilter =
  result.toolsListChanged = requested.toolsListChanged and
    server.toolsListChanged
  result.promptsListChanged = requested.promptsListChanged and
    server.promptsListChanged
  result.resourcesListChanged = requested.resourcesListChanged and
    server.resourcesListChanged
  if server.resourcesSubscribe:
    result.resourceSubscriptions = requested.resourceSubscriptions

proc subscriptionFilterJson(filter: McpSubscriptionFilter): JsonNode =
  result = newJObject()
  if filter.toolsListChanged: result["toolsListChanged"] = %true
  if filter.promptsListChanged: result["promptsListChanged"] = %true
  if filter.resourcesListChanged: result["resourcesListChanged"] = %true
  if filter.resourceSubscriptions.len > 0:
    result["resourceSubscriptions"] = newJArray()
    for uri in filter.resourceSubscriptions:
      result["resourceSubscriptions"].add %uri

proc acknowledgedNotification(id: McpId,
                              filter: McpSubscriptionFilter): JsonNode =
  var params = newJObject()
  params["_meta"] = newJObject()
  params["_meta"]["io.modelcontextprotocol/subscriptionId"] = toJson(id)
  params["notifications"] = subscriptionFilterJson(filter)
  %*{"jsonrpc": mcpJsonRpcVersion,
    "method": "notifications/subscriptions/acknowledged",
    "params": params}

proc openSubscription*(server: McpServer, id: McpId,
                       requested: McpSubscriptionFilter,
                       handler: McpSubscriptionMessageHandler):
                       McpSubscription =
  if server.isNil: raise newMcpError("server must not be nil")
  let filter = server.acknowledgedFilter(requested)
  result = server.eventBus.subscribe(id, filter, handler)
  server.subscriptions.add result
  result.setCloseHandler(proc (subscription: McpSubscription, graceful: bool) =
    discard server.closeSubscription(subscription, graceful))
  result.deliver(acknowledgedNotification(id, filter))
  result.activate()

proc subscriptionCount*(server: McpServer): int =
  if server.isNil: return 0
  for subscription in server.subscriptions:
    if subscription.isActive: inc result

proc findSubscription*(server: McpServer, id: McpId): McpSubscription =
  if server.isNil: return nil
  for subscription in server.subscriptions:
    if subscription.isActive and $toJson(subscription.id) == $toJson(id):
      return subscription

proc closeSubscription*(server: McpServer, subscription: McpSubscription,
                        graceful: bool): bool =
  if server.isNil or subscription.isNil or not subscription.isActive:
    return false
  if graceful:
    var fields = resultObject(server).fields
    fields["_meta"]["io.modelcontextprotocol/subscriptionId"] =
      toJson(subscription.id)
    subscription.deliver(toJson(successResponse(subscription.id,
      newMcpResult(mcpComplete, fields))))
  discard server.eventBus.unsubscribe(subscription)
  for index in countdown(server.subscriptions.high, 0):
    if server.subscriptions[index] == subscription:
      server.subscriptions.delete(index)
      break
  true

proc closeSubscriptions*(server: McpServer, graceful = true): int =
  if server.isNil: return 0
  let subscriptions = server.subscriptions
  for subscription in subscriptions:
    if server.closeSubscription(subscription, graceful): inc result

proc cancelSubscription*(server: McpServer, id: McpId): bool =
  if server.isNil: return false
  for subscription in server.subscriptions:
    if $toJson(subscription.id) == $toJson(id):
      return server.closeSubscription(subscription, graceful = false)
  false

proc addPromptCompletion*(server: McpServer, promptName, argument: string,
                          handler: McpPromptCompletionHandler) =
  if server.isNil: raise newMcpError("server must not be nil")
  let index = server.findPrompt(promptName)
  if index < 0:
    raise newMcpError("unknown prompt: " & promptName)
  server.prompts[index].addCompletion(argument, handler)

proc addPromptCompletion*(server: McpServer, promptName, argument: string,
                          handler: McpSyncPromptCompletionHandler) =
  if handler.isNil: raise newMcpError("prompt completion handler must not be nil")
  server.addPromptCompletion(promptName, argument,
    proc (completionArgument, prefix: string, context: McpContext):
        Future[seq[string]] {.async.} =
      handler(completionArgument, prefix, context))

proc completePromptArgument*(server: McpServer, promptName, argument, prefix: string,
                             context: McpContext): Future[seq[string]] {.async.} =
  if server.isNil: raise newMcpError("server must not be nil")
  let index = server.findPrompt(promptName)
  if index < 0:
    raise newMcpError("unknown prompt: " & promptName)
  await server.prompts[index].completePromptArgument(argument, prefix, context)

proc markPromptsChanged*(server: McpServer) =
  if server.isNil: raise newMcpError("server must not be nil")
  server.promptsListChanged = true
  server.eventBus.publishPromptsChanged()

proc completeResourceTemplate*(server: McpServer, uriTemplate, argument,
                               prefix: string,
                               context: McpContext): Future[seq[string]] {.async.} =
  if server.isNil: raise newMcpError("server must not be nil")
  let index = server.findResourceTemplate(uriTemplate)
  if index < 0:
    raise newMcpError("unknown resource URI template: " & uriTemplate)
  await server.resourceTemplates[index].completeResourceTemplate(argument,
    prefix, context)

proc markToolsChanged*(server: McpServer) =
  if server.isNil: raise newMcpError("server must not be nil")
  server.toolsListChanged = true
  server.eventBus.publishToolsChanged()

proc serverMeta(server: McpServer): JsonNode =
  %*{"io.modelcontextprotocol/serverInfo": {
    "name": server.name,
    "version": server.version
  }}

proc resultObject(server: McpServer): McpResult =
  var fields = newJObject()
  fields["_meta"] = serverMeta(server)
  newMcpResult(mcpComplete, fields)

proc toolJson(tool: McpTool): JsonNode =
  result = %*{"name": tool.name, "description": tool.description,
    "inputSchema": tool.inputSchema}
  if not tool.outputSchema.isNil:
    result["outputSchema"] = tool.outputSchema
  if tool.title.len > 0:
    result["title"] = %tool.title
  if not tool.icons.isNil:
    result["icons"] = tool.icons
  if not tool.annotations.isNil:
    result["annotations"] = tool.annotations

proc resourceJson(resource: McpResource): JsonNode =
  toJson(resource)

proc resourceTemplateJson(resourceTemplate: McpResourceTemplate): JsonNode =
  toJson(resourceTemplate)

proc promptJson(prompt: McpPrompt): JsonNode =
  toJson(prompt)

proc encodeToolsCursor(index: int): string =
  encode("nimwire.tools.list.v1:" & $index)

proc decodeToolsCursor(cursor: string, toolCount: int): int =
  try:
    let decoded = decode(cursor)
    let prefix = "nimwire.tools.list.v1:"
    if decoded.len <= prefix.len or not decoded.startsWith(prefix):
      raise newException(ValueError, "prefix")
    result = parseInt(decoded[prefix.len .. ^1])
  except CatchableError:
    raise newMcpError("tools/list cursor is invalid")
  if result < 0 or result > toolCount:
    raise newMcpError("tools/list cursor is out of range")

proc encodeResourceCursor(index: int): string =
  encode("nimwire.resources.list.v1:" & $index)

proc decodeResourceCursor(cursor, prefix: string, itemCount: int): int =
  try:
    let decoded = decode(cursor)
    if decoded.len <= prefix.len or not decoded.startsWith(prefix):
      raise newException(ValueError, "prefix")
    result = parseInt(decoded[prefix.len .. ^1])
  except CatchableError:
    raise newMcpError("resource list cursor is invalid")
  if result < 0 or result > itemCount:
    raise newMcpError("resource list cursor is out of range")

proc listResources(server: McpServer, params: McpParams): McpResult =
  var fields = resultObject(server).fields
  var resources = server.resources
  resources.sort(proc (a, b: McpResource): int = cmp(a.uri, b.uri))
  let start = if "cursor" in params.values:
    if params.values["cursor"].kind != JString or
        params.values["cursor"].getStr.len == 0:
      raise newMcpError("resources/list cursor must be a non-empty string")
    decodeResourceCursor(params.values["cursor"].getStr,
      "nimwire.resources.list.v1:", resources.len)
  else:
    0
  let finish = if server.listPageSize == 0:
    resources.len
  else:
    min(resources.len, start + server.listPageSize)
  fields["resources"] = newJArray()
  for index in start ..< finish:
    fields["resources"].add resourceJson(resources[index])
  if finish < resources.len:
    fields["nextCursor"] = %encodeResourceCursor(finish)
  fields["ttlMs"] = %server.listTtlMs
  fields["cacheScope"] = %server.listCacheScope
  newMcpResult(mcpComplete, fields)

proc encodeResourceTemplateCursor(index: int): string =
  encode("nimwire.resources.templates.list.v1:" & $index)

proc listResourceTemplates(server: McpServer, params: McpParams): McpResult =
  var fields = resultObject(server).fields
  var templates = server.resourceTemplates
  templates.sort(proc (a, b: McpResourceTemplate): int =
    cmp(a.uriTemplate, b.uriTemplate))
  let start = if "cursor" in params.values:
    if params.values["cursor"].kind != JString or
        params.values["cursor"].getStr.len == 0:
      raise newMcpError("resources/templates/list cursor must be a non-empty string")
    decodeResourceCursor(params.values["cursor"].getStr,
      "nimwire.resources.templates.list.v1:", templates.len)
  else:
    0
  let finish = if server.listPageSize == 0:
    templates.len
  else:
    min(templates.len, start + server.listPageSize)
  fields["resourceTemplates"] = newJArray()
  for index in start ..< finish:
    fields["resourceTemplates"].add resourceTemplateJson(templates[index])
  if finish < templates.len:
    fields["nextCursor"] = %encodeResourceTemplateCursor(finish)
  fields["ttlMs"] = %server.listTtlMs
  fields["cacheScope"] = %server.listCacheScope
  newMcpResult(mcpComplete, fields)

proc encodePromptCursor(index: int): string =
  encode("nimwire.prompts.list.v1:" & $index)

proc listPrompts(server: McpServer, params: McpParams): McpResult =
  var fields = resultObject(server).fields
  var prompts = server.prompts
  prompts.sort(proc (a, b: McpPrompt): int = cmp(a.name, b.name))
  let start = if "cursor" in params.values:
    if params.values["cursor"].kind != JString or
        params.values["cursor"].getStr.len == 0:
      raise newMcpError("prompts/list cursor must be a non-empty string")
    decodeResourceCursor(params.values["cursor"].getStr,
      "nimwire.prompts.list.v1:", prompts.len)
  else:
    0
  let finish = if server.listPageSize == 0:
    prompts.len
  else:
    min(prompts.len, start + server.listPageSize)
  fields["prompts"] = newJArray()
  for index in start ..< finish:
    fields["prompts"].add promptJson(prompts[index])
  if finish < prompts.len:
    fields["nextCursor"] = %encodePromptCursor(finish)
  fields["ttlMs"] = %server.listTtlMs
  fields["cacheScope"] = %server.listCacheScope
  newMcpResult(mcpComplete, fields)

proc listTools(server: McpServer, params: McpParams): McpResult =
  var fields = resultObject(server).fields
  var tools = server.tools
  tools.sort(proc (a, b: McpTool): int = cmp(a.name, b.name))
  let start = if "cursor" in params.values:
    if params.values["cursor"].kind != JString or
        params.values["cursor"].getStr.len == 0:
      raise newMcpError("tools/list cursor must be a non-empty string")
    decodeToolsCursor(params.values["cursor"].getStr, tools.len)
  else:
    0
  let finish = if server.listPageSize == 0:
    tools.len
  else:
    min(tools.len, start + server.listPageSize)
  fields["tools"] = newJArray()
  for index in start ..< finish:
    fields["tools"].add toolJson(tools[index])
  if finish < tools.len:
    fields["nextCursor"] = %encodeToolsCursor(finish)
  fields["ttlMs"] = %server.listTtlMs
  fields["cacheScope"] = %server.listCacheScope
  newMcpResult(mcpComplete, fields)

proc discover(server: McpServer): McpResult =
  var fields = resultObject(server).fields
  fields["supportedVersions"] = %*[mcpProtocolVersion]
  fields["capabilities"] = %*{"tools": {
    "listChanged": server.toolsListChanged
  }}
  if server.resources.len > 0 or server.resourceTemplates.len > 0:
    let resources = %*{
      "listChanged": server.resourcesListChanged,
      "subscribe": server.resourcesSubscribe
    }
    fields["capabilities"]["resources"] = resources
  if server.prompts.len > 0:
    fields["capabilities"]["prompts"] = %*{
      "listChanged": server.promptsListChanged
    }
  if server.prompts.len > 0 or server.resourceTemplates.len > 0:
    fields["capabilities"]["completions"] = %*{}
  if server.instructions.len > 0:
    fields["instructions"] = %server.instructions
  newMcpResult(mcpComplete, fields)

proc findTool*(server: McpServer, name: string): int =
  for i, tool in server.tools:
    if tool.name == name: return i
  -1

iterator toolHeaderBindings*(server: McpServer,
                             name: string): McpHeaderBinding =
  let index = server.findTool(name)
  if index >= 0:
    for binding in server.tools[index].headerBindings:
      yield binding

proc callTool(server: McpServer, params: McpParams,
              context: McpContext): Future[McpResult] {.async.} =
  context.checkCancelled()
  let name = requiredString(params.values, "name", "tools/call params")
  let arguments = if "arguments" in params.values:
    requireObject(params.values["arguments"], "tools/call arguments")
  else:
    newJObject()
  let index = server.findTool(name)
  if index < 0:
    raise newMcpError("unknown tool: " & name)
  validateJsonValue(server.tools[index].inputSchema, arguments,
    "tool '" & name & "' arguments")
  let output = await server.tools[index].handler(arguments, context)
  context.checkCancelled()
  if context.hasInputRequired:
    return context.inputRequired
  if not output.structuredContent.isNil and
      not server.tools[index].outputSchema.isNil:
    try:
      validateJsonValue(server.tools[index].outputSchema,
        output.structuredContent, "tool '" & name & "' structuredContent")
    except McpError as error:
      raise newMcpError("tool '" & name & "' returned invalid structuredContent: " &
        error.msg, mcpInternalErrorCode, error.data)
  var content = output.content
  if content.isNil:
    content = newJArray()
  if content.kind != JArray:
    raise newMcpError("tool '" & name & "' returned invalid content",
      mcpInternalErrorCode)
  if not output.structuredContent.isNil and content.len == 0:
    content = newJArray()
    content.add textContent($output.structuredContent)
  var fields = resultObject(server).fields
  fields["content"] = content
  fields["isError"] = %output.isError
  if not output.structuredContent.isNil:
    fields["structuredContent"] = output.structuredContent
  newMcpResult(mcpComplete, fields)

proc readResourceRequest(server: McpServer, params: McpParams,
                         context: McpContext): Future[McpResult] {.async.} =
  let uri = requiredString(params.values, "uri", "resources/read params")
  validateResourceUri(uri, "resources/read")
  var contents: seq[McpResourceContent]
  var mimeType = ""
  let resourceIndex = server.findResource(uri)
  if resourceIndex >= 0:
    let resource = server.resources[resourceIndex]
    contents = await resource.readResource(uri, context)
    mimeType = resource.mimeType
  else:
    var matched = false
    for resourceTemplate in server.resourceTemplates:
      let arguments = resourceTemplate.matchResourceTemplate(uri)
      if arguments.isNil: continue
      contents = await resourceTemplate.readResourceTemplate(uri, arguments,
        context)
      mimeType = resourceTemplate.mimeType
      matched = true
      break
    if not matched:
      raise newMcpError("Resource not found", mcpInvalidParamsCode,
        %*{"uri": uri})
  if context.hasInputRequired:
    return context.inputRequired
  var fields = resultObject(server).fields
  fields["contents"] = newJArray()
  for content in contents:
    fields["contents"].add resourceContentJson(content, mimeType)
  fields["ttlMs"] = %server.listTtlMs
  fields["cacheScope"] = %server.listCacheScope
  newMcpResult(mcpComplete, fields)

proc getPromptRequest(server: McpServer, params: McpParams,
                      context: McpContext): Future[McpResult] {.async.} =
  let name = requiredString(params.values, "name", "prompts/get params")
  let index = server.findPrompt(name)
  if index < 0:
    raise newMcpError("Prompt not found", mcpInvalidParamsCode, %*{"name": name})
  let values = if "arguments" in params.values:
    requireObject(params.values["arguments"], "prompts/get arguments")
  else:
    newJObject()
  let prompt = server.prompts[index]
  let arguments = prompt.decodePromptArguments(values)
  context.checkCancelled()
  let messages = await prompt.runPrompt(arguments, context)
  context.checkCancelled()
  if context.hasInputRequired:
    return context.inputRequired
  var fields = resultObject(server).fields
  if prompt.description.len > 0:
    fields["description"] = %prompt.description
  fields["messages"] = newJArray()
  for message in messages:
    fields["messages"].add toJson(message)
  newMcpResult(mcpComplete, fields)

proc completionArguments(value: JsonNode, label: string): JsonNode =
  if value.isNil or value.kind != JObject:
    raise newMcpError(label & " must be an object")
  for name, argument in value.pairs:
    if argument.kind != JString:
      raise newMcpError(label & " argument '" & name & "' must be a string")
  value

proc completionResult(server: McpServer, values: seq[string]): McpResult =
  var completion = %*{
    "values": newJArray(),
    "total": values.len,
    "hasMore": values.len > mcpDefaultCompletionLimit
  }
  let visible = min(values.len, mcpDefaultCompletionLimit)
  for index in 0 ..< visible:
    completion["values"].add %values[index]
  var fields = resultObject(server).fields
  fields["completion"] = completion
  newMcpResult(mcpComplete, fields)

proc completeRequest(server: McpServer, params: McpParams,
                     context: McpContext): Future[McpResult] {.async.} =
  if "ref" notin params.values:
    raise newMcpError("completion/complete requires 'ref'")
  if "argument" notin params.values:
    raise newMcpError("completion/complete requires 'argument'")
  let reference = requireObject(params.values["ref"],
    "completion/complete ref")
  let referenceType = requiredString(reference, "type",
    "completion/complete ref")
  let argument = requireObject(params.values["argument"],
    "completion/complete argument")
  let argumentName = requiredString(argument, "name",
    "completion/complete argument")
  if "value" notin argument or argument["value"].kind != JString:
    raise newMcpError("completion/complete argument requires a string 'value'")
  let prefix = argument["value"].getStr
  let priorArguments = if "context" in params.values:
    let requestContext = requireObject(params.values["context"],
      "completion/complete context")
    if "arguments" in requestContext:
      completionArguments(requestContext["arguments"],
        "completion/complete context arguments")
    else:
      newJObject()
  else:
    newJObject()
  context.completionArguments = priorArguments
  case referenceType
  of "ref/prompt":
    let name = requiredString(reference, "name", "completion prompt ref")
    let index = server.findPrompt(name)
    if index < 0:
      raise newMcpError("unknown prompt: " & name)
    let prompt = server.prompts[index]
    for priorName in priorArguments.keys:
      var known = false
      for promptArgument in prompt.arguments:
        if promptArgument.name == priorName:
          known = true
          break
      if not known:
        raise newMcpError("unknown prompt argument: " & priorName)
    let values = await server.completePromptArgument(name, argumentName,
      prefix, context)
    server.completionResult(values)
  of "ref/resource":
    let uri = requiredString(reference, "uri", "completion resource ref")
    var index = server.findResourceTemplate(uri)
    if index < 0:
      for candidate in 0 ..< server.resourceTemplates.len:
        if not server.resourceTemplates[candidate].matchResourceTemplate(uri).isNil:
          index = candidate
          break
    if index < 0:
      raise newMcpError("unknown resource template: " & uri)
    let resourceTemplate = server.resourceTemplates[index]
    let templateArguments = resourceTemplateVariables(resourceTemplate.uriTemplate)
    if argumentName notin templateArguments:
      raise newMcpError("unknown resource template argument: " & argumentName)
    for priorName in priorArguments.keys:
      if priorName notin templateArguments:
        raise newMcpError("unknown resource template argument: " & priorName)
    let values = await server.completeResourceTemplate(
      resourceTemplate.uriTemplate, argumentName, prefix, context)
    server.completionResult(values)
  else:
    raise newMcpError("unsupported completion reference type: " & referenceType)

proc prepareContext(server: McpServer, context: McpContext) =
  if context.isNil: return
  if not server.requestStateSealer.isNil:
    context.requestStateSealer = server.requestStateSealer
  if not server.requestStateVerifier.isNil:
    context.requestStateVerifier = server.requestStateVerifier

proc validateRoundTripRequest(server: McpServer, request: McpRpcRequest,
                              context: McpContext) =
  if "inputResponses" notin request.params.values and
      "requestState" notin request.params.values:
    return
  if request.methodName notin ["tools/call", "prompts/get", "resources/read"]:
    raise newMcpError("inputResponses and requestState are only valid on tools/call, prompts/get, or resources/read")
  discard context.verifyRequestState()

proc dispatchAsync*(server: McpServer, request: McpRpcRequest,
                    context: McpContext): Future[McpResult] {.async.} =
  context.checkCancelled()
  case request.methodName
  of "server/discover":
    result = server.discover()
  of "ping":
    result = server.resultObject()
  of "tools/list":
    result = server.listTools(request.params)
  of "tools/call":
    result = await server.callTool(request.params, context)
  of "resources/list":
    result = server.listResources(request.params)
  of "resources/read":
    result = await server.readResourceRequest(request.params, context)
  of "resources/templates/list":
    result = server.listResourceTemplates(request.params)
  of "prompts/list":
    result = server.listPrompts(request.params)
  of "prompts/get":
    result = await server.getPromptRequest(request.params, context)
  of "completion/complete":
    result = await server.completeRequest(request.params, context)
  else:
    raise newMcpError("Method not found: " & request.methodName,
      mcpMethodNotFoundCode)

proc handleMessageAsync*(server: McpServer, message: McpJsonRpcMessage,
                         context: McpContext,
                         subscriptionHandler: McpSubscriptionMessageHandler = nil):
                         Future[Option[McpJsonRpcMessage]] {.async.} =
  case message.kind
  of mcpRequestMessage, mcpNotificationMessage:
    let request = message.request
    try:
      server.prepareContext(context)
      server.validateRoundTripRequest(request, context)
      if request.methodName == "subscriptions/listen":
        if request.kind != mcpRequest:
          raise newMcpError("subscriptions/listen requires a request id",
            mcpInvalidRequestCode)
        if "notifications" notin request.params.values:
          raise newMcpError("subscriptions/listen requires 'notifications'")
        let filter = parseSubscriptionFilter(
          request.params.values["notifications"])
        if subscriptionHandler.isNil:
          var acknowledgment: JsonNode
          let capture: McpSubscriptionMessageHandler =
            proc (message: JsonNode) =
              if acknowledgment.isNil: acknowledgment = message
          let subscription = server.openSubscription(request.id, filter, capture)
          let message = parseMcpMessage(acknowledgment)
          discard server.closeSubscription(subscription, graceful = false)
          return some(message)
        discard server.openSubscription(request.id, filter, subscriptionHandler)
        return none(McpJsonRpcMessage)
      if request.methodName == "notifications/cancelled":
        if "requestId" in request.params.values:
          try:
            let subscriptionId = parseMcpId(request.params.values["requestId"])
            discard server.cancelSubscription(subscriptionId)
          except CatchableError:
            discard
        return none(McpJsonRpcMessage)
      let value = await server.dispatchAsync(request, context)
      if request.kind == mcpNotification:
        return none(McpJsonRpcMessage)
      return some(successResponse(request.id, value))
    except McpError as error:
      if request.kind == mcpNotification:
        return none(McpJsonRpcMessage)
      return some(errorResponse(request.id, error.code, error.msg, error.data))
    except CatchableError as error:
      context.log(mcpLogError, error.msg)
      if request.kind == mcpNotification:
        return none(McpJsonRpcMessage)
      return some(errorResponse(request.id, mcpInternalErrorCode,
        "Internal server error"))
  of mcpResponseMessage, mcpErrorMessage:
    some(errorResponse(McpId(kind: mcpNullId), mcpInvalidRequestCode,
      "server accepts requests and notifications only"))

proc handleJsonAsync*(server: McpServer,
                      request: JsonNode): Future[JsonNode] {.async.} =
  ## Decode one JSON-RPC message, dispatch its typed form, then encode it.
  if request.isNil or request.kind != JObject:
    return toJson(errorResponse(McpId(kind: mcpNullId),
      mcpInvalidRequestCode, "Invalid Request"))
  let isNotification = "id" notin request
  var context: McpContext
  try:
    let message = parseMcpMessage(request)
    context = if message.kind in {mcpRequestMessage, mcpNotificationMessage}:
      newMcpContext(message.request)
    else:
      nil
    let output = await server.handleMessageAsync(message, context)
    if output.isNone:
      return nil
    return toJson(output.get)
  except McpError as error:
    if isNotification:
      return nil
    return toJson(errorResponse(requestIdOrNull(request), error.code,
      error.msg, error.data))
  except CatchableError as error:
    context.log(mcpLogError, error.msg)
    if isNotification:
      return nil
    return toJson(errorResponse(requestIdOrNull(request), mcpInternalErrorCode,
      "Internal server error"))

proc handleJson*(server: McpServer, request: JsonNode): JsonNode =
  waitFor server.handleJsonAsync(request)
