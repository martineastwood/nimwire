## Optional composition of a remote MCP peer into a local server.

import std/[asyncdispatch, base64, json, strutils, tables, uri]

import ./core
import ./context
import ./prompts
import ./resources
import ./schema
import ./server
import ./transport

type
  McpProxy* = ref object
    ## A discovered remote peer mounted into a local McpServer.
    peer*: McpPeer
    namespace*: string

proc proxyName(namespace, name: string): string =
  namespace & "." & name

proc proxyToolName(namespace, name: string): string =
  result = proxyName(namespace, name)
  validateToolName(result)

proc proxyResourceUri(namespace, uri: string): string =
  "urn:nimwire:proxy:" & namespace & ":" & encode(uri, safe = true)

proc proxyResourceTemplate(namespace, uriTemplate: string): string =
  "urn:nimwire:proxy:" & namespace & ":" & uriTemplate

proc optionalRemoteString(node: JsonNode, key: string): string =
  if not node.isNil and node.kind == JObject and key in node and
      node[key].kind == JString:
    return node[key].getStr

proc optionalRemoteObject(node: JsonNode, key, context: string): JsonNode =
  if key notin node: return nil
  if node[key].kind != JObject:
    raise newMcpError(context & " '" & key & "' must be an object")
  return node[key]

proc optionalRemoteValue(node: JsonNode, key: string): JsonNode =
  if not node.isNil and node.kind == JObject and key in node:
    return node[key]

proc pagedListAsync(peer: McpPeer, methodName, fieldName: string):
    Future[seq[JsonNode]] {.async.} =
  var cursor = ""
  var seenCursors: seq[string]
  while true:
    let params = if cursor.len == 0: newJObject() else: %*{"cursor": cursor}
    let response = await peer.requestAsync(methodName, params)
    if response.resultType != mcpComplete:
      raise newMcpError(methodName & " did not return a complete result")
    if fieldName notin response.fields or
        response.fields[fieldName].kind != JArray:
      raise newMcpError(methodName & " returned no " & fieldName & " array")
    for item in response.fields[fieldName].items:
      if item.kind != JObject:
        raise newMcpError(methodName & " returned a non-object item")
      result.add item
    if "nextCursor" notin response.fields: return
    if response.fields["nextCursor"].kind != JString or
        response.fields["nextCursor"].getStr.len == 0:
      raise newMcpError(methodName & " returned an invalid nextCursor")
    cursor = response.fields["nextCursor"].getStr
    if cursor in seenCursors:
      raise newMcpError(methodName & " returned a repeated nextCursor")
    seenCursors.add cursor

proc remoteToolResult(peer: McpPeer, remoteName: string,
                      arguments: JsonNode): Future[McpToolResult] {.async.} =
  let response = await peer.requestAsync("tools/call", %*{
    "name": remoteName, "arguments": arguments})
  if response.resultType != mcpComplete:
    raise newMcpError("remote tool '" & remoteName & "' did not complete")
  let fields = response.fields
  let content = if "content" in fields: fields["content"] else: newJArray()
  let structured = if "structuredContent" in fields:
    fields["structuredContent"] else: nil
  let isError = "isError" in fields and fields["isError"].kind == JBool and
    fields["isError"].getBool
  newMcpToolResult(content, structured, isError)

proc remoteResourceContents(peer: McpPeer, remoteUri, localUri: string,
                            defaultMimeType: string):
                            Future[seq[McpResourceContent]] {.async.} =
  let response = await peer.requestAsync("resources/read", %*{"uri": remoteUri})
  if response.resultType != mcpComplete:
    raise newMcpError("remote resource '" & remoteUri & "' did not complete")
  if "contents" notin response.fields or
      response.fields["contents"].kind != JArray:
    raise newMcpError("remote resource returned no contents array")
  for item in response.fields["contents"].items:
    if item.kind != JObject:
      raise newMcpError("remote resource returned a non-object content")
    let mimeType = if "mimeType" in item and
        item["mimeType"].kind == JString: item["mimeType"].getStr
      else: defaultMimeType
    if "text" in item and item["text"].kind == JString:
      result.add resourceText(localUri, item["text"].getStr, mimeType)
    elif "blob" in item and item["blob"].kind == JString:
      result.add resourceBlob(localUri, item["blob"].getStr, mimeType)
    else:
      raise newMcpError("remote resource content requires text or blob")

proc templateVariable(expression: string): string =
  result = expression
  if result.len > 0 and result[0] in {'+', '#', '.', '/', ';', '?', '&'}:
    result = result[1 .. ^1]
  if result.endsWith("*"): result.setLen(result.len - 1)

proc expandRemoteTemplate(uriTemplate: string, arguments: JsonNode): string =
  var position = 0
  while position < uriTemplate.len:
    let open = uriTemplate.find('{', position)
    if open < 0:
      result.add uriTemplate[position .. ^1]
      break
    result.add uriTemplate[position ..< open]
    let close = uriTemplate.find('}', open + 1)
    if close < 0:
      raise newMcpError("remote resource URI template has an unmatched '{'")
    let name = templateVariable(uriTemplate[open + 1 ..< close])
    if arguments.isNil or arguments.kind != JObject or name notin arguments or
        arguments[name].kind != JString:
      raise newMcpError("remote resource URI template argument is missing: " & name)
    result.add encodeUrl(arguments[name].getStr, false)
    position = close + 1

proc remotePromptMessages(peer: McpPeer, remoteName: string,
                          arguments: McpPromptArguments):
                          Future[seq[McpPromptMessage]] {.async.} =
  var values = newJObject()
  for name, value in arguments:
    values[name] = %value
  let response = await peer.requestAsync("prompts/get", %*{
    "name": remoteName, "arguments": values})
  if response.resultType != mcpComplete:
    raise newMcpError("remote prompt '" & remoteName & "' did not complete")
  if "messages" notin response.fields or
      response.fields["messages"].kind != JArray:
    raise newMcpError("remote prompt returned no messages array")
  for item in response.fields["messages"].items:
    let role = requiredString(item, "role", "remote prompt message")
    let content = if item.kind == JObject and "content" in item:
      item["content"] else: nil
    validatePromptContent(content)
    let promptRole = case role
      of "user": mcpPromptUser
      of "assistant": mcpPromptAssistant
      else: raise newMcpError("remote prompt has an unsupported role: " & role)
    result.add McpPromptMessage(role: promptRole, content: content)

proc remoteCompletion(peer: McpPeer, reference: JsonNode, argument, prefix: string,
                      context: McpContext): Future[seq[string]] {.async.} =
  var params = %*{"ref": reference, "argument": {
    "name": argument, "value": prefix}}
  if not context.isNil and not context.completionArguments.isNil:
    params["context"] = %*{"arguments": context.completionArguments}
  let response = await peer.requestAsync("completion/complete", params)
  if response.resultType != mcpComplete or "completion" notin response.fields or
      response.fields["completion"].kind != JObject:
    raise newMcpError("remote completion returned an invalid result")
  let completion = response.fields["completion"]
  if "values" notin completion or completion["values"].kind != JArray:
    raise newMcpError("remote completion returned no values")
  for value in completion["values"].items:
    if value.kind != JString:
      raise newMcpError("remote completion values must be strings")
    result.add value.getStr

proc newMcpProxy*(transport: McpMessageTransport,
                  namespace = "remote"): McpProxy =
  if transport.isNil: raise newMcpError("MCP proxy transport must not be nil")
  validateToolName(namespace)
  McpProxy(peer: newMcpPeer(transport), namespace: namespace)

proc proxyTool(proxy: McpProxy, item: JsonNode): McpTool =
  let remoteName = requiredString(item, "name", "remote tool")
  let inputSchema = if "inputSchema" in item: item["inputSchema"] else: nil
  discard requireJsonSchema(inputSchema, "remote tool inputSchema")
  let handler: McpToolHandler = proc (arguments: JsonNode,
                                      context: McpContext):
                                      Future[McpToolResult] {.async.} =
    discard context
    await proxy.peer.remoteToolResult(remoteName, arguments)
  let outputSchema = if "outputSchema" in item: item["outputSchema"] else: nil
  let title = optionalRemoteString(item, "title")
  let remoteDescription = optionalRemoteString(item, "description")
  let description = if remoteDescription.len > 0: remoteDescription else: remoteName
  let icons = optionalRemoteValue(item, "icons")
  let annotations = optionalRemoteObject(item, "annotations", "remote tool")
  newMcpTool(proxyToolName(proxy.namespace, remoteName), description, inputSchema,
    handler, outputSchema, title, icons, annotations)

proc proxyResource(proxy: McpProxy, item: JsonNode): McpResource =
  let remoteUri = requiredString(item, "uri", "remote resource")
  let localUri = proxyResourceUri(proxy.namespace, remoteUri)
  let remoteMimeType = optionalRemoteString(item, "mimeType")
  let handler: McpResourceReadHandler = proc (uri: string,
                                              context: McpContext):
                                              Future[seq[McpResourceContent]] {.async.} =
    discard context
    await proxy.peer.remoteResourceContents(remoteUri, uri, remoteMimeType)
  let remoteName = optionalRemoteString(item, "name")
  let name = if remoteName.len > 0: remoteName else: remoteUri
  let title = optionalRemoteString(item, "title")
  let description = optionalRemoteString(item, "description")
  let icons = optionalRemoteValue(item, "icons")
  let annotations = optionalRemoteObject(item, "annotations", "remote resource")
  let size = if "size" in item and item["size"].kind == JInt:
    item["size"].getInt.int64 else: -1
  newMcpResource(localUri, proxyName(proxy.namespace, name), handler, title,
    description, icons, remoteMimeType, size, annotations)

proc proxyResourceTemplate(proxy: McpProxy, item: JsonNode):
                          McpResourceTemplate =
  let remoteTemplate = requiredString(item, "uriTemplate",
    "remote resource template")
  let localTemplate = proxyResourceTemplate(proxy.namespace, remoteTemplate)
  let remoteMimeType = optionalRemoteString(item, "mimeType")
  let handler: McpResourceTemplateReadHandler = proc (uri: string,
      arguments: JsonNode, context: McpContext):
      Future[seq[McpResourceContent]] {.async.} =
    discard context
    let remoteUri = expandRemoteTemplate(remoteTemplate, arguments)
    await proxy.peer.remoteResourceContents(remoteUri, uri, remoteMimeType)
  let remoteName = optionalRemoteString(item, "name")
  let name = if remoteName.len > 0: remoteName else: remoteTemplate
  let title = optionalRemoteString(item, "title")
  let description = optionalRemoteString(item, "description")
  let icons = optionalRemoteValue(item, "icons")
  let annotations = optionalRemoteObject(item, "annotations",
    "remote resource template")
  newMcpResourceTemplate(localTemplate, proxyName(proxy.namespace, name),
    handler, title, description, icons, remoteMimeType, annotations)

proc promptArguments(item: JsonNode): seq[McpPromptArgument] =
  if "arguments" notin item: return
  if item["arguments"].kind != JArray:
    raise newMcpError("remote prompt arguments must be an array")
  for value in item["arguments"].items:
    let name = requiredString(value, "name", "remote prompt argument")
    let description = optionalRemoteString(value, "description")
    let required = "required" in value and value["required"].kind == JBool and
      value["required"].getBool
    result.add newMcpPromptArgument(name, description, required)

proc proxyPrompt(proxy: McpProxy, item: JsonNode): McpPrompt =
  let remoteName = requiredString(item, "name", "remote prompt")
  let handler: McpPromptHandler = proc (arguments: McpPromptArguments,
                                        context: McpContext):
                                        Future[seq[McpPromptMessage]] {.async.} =
    discard context
    await proxy.peer.remotePromptMessages(remoteName, arguments)
  let title = optionalRemoteString(item, "title")
  let description = optionalRemoteString(item, "description")
  let icons = optionalRemoteValue(item, "icons")
  newMcpPrompt(proxyName(proxy.namespace, remoteName), handler, title,
    description, promptArguments(item), icons)

proc addProxyPromptCompletions(server: McpServer, proxy: McpProxy,
                               prompt: McpPrompt, remoteName: string) =
  for promptArgument in prompt.arguments:
    let argument = promptArgument.name
    let handler: McpPromptCompletionHandler = proc (
        completionArgument, prefix: string, context: McpContext):
        Future[seq[string]] {.async.} =
      discard completionArgument
      await proxy.peer.remoteCompletion(
        %*{"type": "ref/prompt", "name": remoteName}, argument, prefix,
        context)
    server.addPromptCompletion(prompt.name, argument, handler)

proc addProxyResourceCompletions(server: McpServer, proxy: McpProxy,
                                 resourceTemplate: McpResourceTemplate,
                                 remoteTemplate: string) =
  for templateArgument in resourceTemplateVariables(
      resourceTemplate.uriTemplate):
    let argument = templateArgument
    let handler: McpResourceCompletionHandler = proc (
        completionArgument, prefix: string, context: McpContext):
        Future[seq[string]] {.async.} =
      discard completionArgument
      await proxy.peer.remoteCompletion(
        %*{"type": "ref/resource", "uri": remoteTemplate}, argument,
        prefix, context)
    server.addResourceTemplateCompletion(resourceTemplate.uriTemplate,
      argument, handler)

proc checkProxyCollisions(server: McpServer, tools: seq[McpTool],
                          resources: seq[McpResource],
                          templates: seq[McpResourceTemplate],
                          prompts: seq[McpPrompt]) =
  var names: seq[string]
  for tool in tools:
    let name = tool.toolName
    if server.findTool(name) >= 0 or name in names:
      raise newMcpError("proxy tool name collides: " & name)
    names.add name
  names.setLen(0)
  for resource in resources:
    if server.findResource(resource.uri) >= 0 or resource.uri in names:
      raise newMcpError("proxy resource URI collides: " & resource.uri)
    names.add resource.uri
  names.setLen(0)
  for resourceTemplate in templates:
    if server.findResourceTemplate(resourceTemplate.uriTemplate) >= 0 or
        resourceTemplate.uriTemplate in names:
      raise newMcpError("proxy resource template collides: " &
        resourceTemplate.uriTemplate)
    names.add resourceTemplate.uriTemplate
  names.setLen(0)
  for prompt in prompts:
    if server.findPrompt(prompt.name) >= 0 or prompt.name in names:
      raise newMcpError("proxy prompt name collides: " & prompt.name)
    names.add prompt.name

proc mountMcpServerAsync*(server: McpServer, proxy: McpProxy):
    Future[void] {.async.} =
  if server.isNil: raise newMcpError("MCP proxy target server must not be nil")
  if proxy.isNil or proxy.peer.isNil:
    raise newMcpError("MCP proxy must not be nil")
  let discovery = await proxy.peer.requestAsync("server/discover")
  if discovery.resultType != mcpComplete or "capabilities" notin discovery.fields:
    raise newMcpError("remote server discovery returned invalid capabilities")
  let capabilities = discovery.fields["capabilities"]
  var tools: seq[McpTool]
  var resources: seq[McpResource]
  var templates: seq[McpResourceTemplate]
  var prompts: seq[McpPrompt]
  var remotePromptNames: seq[string]
  var remoteTemplateNames: seq[string]
  if capabilities.kind == JObject and "tools" in capabilities:
    for item in await pagedListAsync(proxy.peer, "tools/list", "tools"):
      tools.add proxy.proxyTool(item)
  if capabilities.kind == JObject and "resources" in capabilities:
    for item in await pagedListAsync(proxy.peer, "resources/list", "resources"):
      resources.add proxy.proxyResource(item)
    for item in await pagedListAsync(proxy.peer, "resources/templates/list",
                                     "resourceTemplates"):
      templates.add proxy.proxyResourceTemplate(item)
      remoteTemplateNames.add requiredString(item, "uriTemplate",
        "remote resource template")
  if capabilities.kind == JObject and "prompts" in capabilities:
    for item in await pagedListAsync(proxy.peer, "prompts/list", "prompts"):
      prompts.add proxy.proxyPrompt(item)
      remotePromptNames.add requiredString(item, "name", "remote prompt")
  server.checkProxyCollisions(tools, resources, templates, prompts)
  for tool in tools: server.addTool(tool)
  for resource in resources: server.addResource(resource)
  for index, resourceTemplate in templates:
    server.addResourceTemplate(resourceTemplate)
    if capabilities.kind == JObject and "completions" in capabilities:
      server.addProxyResourceCompletions(proxy, resourceTemplate,
        remoteTemplateNames[index])
  for index, prompt in prompts:
    server.addPrompt(prompt)
    if capabilities.kind == JObject and "completions" in capabilities:
      server.addProxyPromptCompletions(proxy, prompt, remotePromptNames[index])
  if tools.len > 0: server.markToolsChanged()
  if resources.len > 0 or templates.len > 0: server.markResourcesChanged()
  if prompts.len > 0: server.markPromptsChanged()

proc mountMcpServerAsync*(server: McpServer, transport: McpMessageTransport,
                          namespace = "remote"): Future[McpProxy] {.async.} =
  let proxy = newMcpProxy(transport, namespace)
  await server.mountMcpServerAsync(proxy)
  proxy

proc mountMcpServer*(server: McpServer, proxy: McpProxy) =
  waitFor server.mountMcpServerAsync(proxy)

proc mountMcpServer*(server: McpServer, transport: McpMessageTransport,
                     namespace = "remote"): McpProxy =
  waitFor server.mountMcpServerAsync(transport, namespace)

proc mountMcpProxyAsync*(server: McpServer, transport: McpMessageTransport,
                         namespace = "remote"): Future[McpProxy] {.async.} =
  await server.mountMcpServerAsync(transport, namespace)

proc mountMcpProxy*(server: McpServer, transport: McpMessageTransport,
                    namespace = "remote"): McpProxy =
  server.mountMcpServer(transport, namespace)
