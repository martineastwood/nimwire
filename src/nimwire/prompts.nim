## Prompt definitions, typed arguments, and prompt messages.

import std/[asyncdispatch, json, tables]

import ./context
import ./core

type
  McpPromptRole* = enum
    mcpPromptUser
    mcpPromptAssistant

  McpPromptArgument* = object
    name*: string
    description*: string
    required*: bool

  McpPromptArguments* = Table[string, string]

  McpPromptMessage* = object
    role*: McpPromptRole
    content*: JsonNode

  McpPromptHandler* = proc (arguments: McpPromptArguments,
                            context: McpContext):
                            Future[seq[McpPromptMessage]] {.closure.}
  McpPromptSingleHandler* = proc (arguments: McpPromptArguments,
                                  context: McpContext):
                                  Future[McpPromptMessage] {.closure.}
  McpSyncPromptHandler* = proc (arguments: McpPromptArguments,
                                context: McpContext):
                                seq[McpPromptMessage] {.closure.}
  McpSyncPromptSingleHandler* = proc (arguments: McpPromptArguments,
                                      context: McpContext):
                                      McpPromptMessage {.closure.}
  McpPromptCompletionHandler* = proc (argument, prefix: string,
                                      context: McpContext):
                                      Future[seq[string]] {.closure.}
  McpSyncPromptCompletionHandler* = proc (argument, prefix: string,
                                          context: McpContext):
                                          seq[string] {.closure.}

  McpPrompt* = object
    name*: string
    title*: string
    description*: string
    icons*: JsonNode
    arguments*: seq[McpPromptArgument]
    handler: McpPromptHandler
    completions: Table[string, McpPromptCompletionHandler]

proc invalidPrompt(message: string): ref McpError =
  newMcpError(message)

proc validatePromptPresentation(icons: JsonNode) =
  if icons.isNil: return
  if icons.kind != JArray:
    raise invalidPrompt("prompt icons must be an array")
  for icon in icons.items:
    if icon.kind != JObject or "src" notin icon or
        icon["src"].kind != JString or icon["src"].getStr.len == 0:
      raise invalidPrompt("prompt icons require a non-empty src")
    if "mimeType" in icon and icon["mimeType"].kind != JString:
      raise invalidPrompt("prompt icon mimeType must be a string")
    if "sizes" in icon:
      if icon["sizes"].kind != JArray:
        raise invalidPrompt("prompt icon sizes must be an array")
      for size in icon["sizes"].items:
        if size.kind != JString or size.getStr.len == 0:
          raise invalidPrompt("prompt icon sizes must be strings")

proc newMcpPromptArgument*(name: string, description = "", required = false):
    McpPromptArgument =
  if name.len == 0:
    raise invalidPrompt("prompt argument name must not be empty")
  McpPromptArgument(name: name, description: description, required: required)

proc validatePromptContent*(content: JsonNode) =
  if content.isNil or content.kind != JObject:
    raise invalidPrompt("prompt message content must be an object")
  if "type" notin content or content["type"].kind != JString:
    raise invalidPrompt("prompt message content requires a string type")
  case content["type"].getStr
  of "text":
    if "text" notin content or content["text"].kind != JString:
      raise invalidPrompt("text prompt content requires text")
  of "image", "audio":
    if "data" notin content or content["data"].kind != JString or
        "mimeType" notin content or content["mimeType"].kind != JString or
        content["mimeType"].getStr.len == 0:
      raise invalidPrompt("media prompt content requires data and mimeType")
  of "resource_link":
    if "uri" notin content or content["uri"].kind != JString or
        content["uri"].getStr.len == 0 or "name" notin content or
        content["name"].kind != JString or content["name"].getStr.len == 0:
      raise invalidPrompt("resource link prompt content requires uri and name")
  of "resource":
    if "resource" notin content or content["resource"].kind != JObject:
      raise invalidPrompt("embedded resource prompt content requires resource")
    let resource = content["resource"]
    if "uri" notin resource or resource["uri"].kind != JString or
        resource["uri"].getStr.len == 0:
      raise invalidPrompt("embedded resource prompt content requires uri")
    if ("text" in resource) == ("blob" in resource):
      raise invalidPrompt("embedded resource prompt content requires text or blob")
    if "text" in resource and resource["text"].kind != JString:
      raise invalidPrompt("embedded resource text must be a string")
    if "blob" in resource and resource["blob"].kind != JString:
      raise invalidPrompt("embedded resource blob must be a string")
  else:
    raise invalidPrompt("unsupported prompt content type: " &
      content["type"].getStr)
  if "annotations" in content and content["annotations"].kind != JObject:
    raise invalidPrompt("prompt content annotations must be an object")

proc newMcpPromptMessage*(role: McpPromptRole,
                          content: JsonNode): McpPromptMessage =
  validatePromptContent(content)
  McpPromptMessage(role: role, content: content)

proc userPrompt*(content: JsonNode): McpPromptMessage =
  newMcpPromptMessage(mcpPromptUser, content)

proc assistantPrompt*(content: JsonNode): McpPromptMessage =
  newMcpPromptMessage(mcpPromptAssistant, content)

proc userText*(text: string, annotations: JsonNode = nil): McpPromptMessage =
  userPrompt(textContent(text, annotations))

proc assistantText*(text: string,
                    annotations: JsonNode = nil): McpPromptMessage =
  assistantPrompt(textContent(text, annotations))

proc promptRoleName(role: McpPromptRole): string =
  case role
  of mcpPromptUser: "user"
  of mcpPromptAssistant: "assistant"

proc toJson*(message: McpPromptMessage): JsonNode =
  %*{"role": message.role.promptRoleName, "content": message.content}

proc promptArgumentJson(argument: McpPromptArgument): JsonNode =
  result = %*{"name": argument.name, "required": argument.required}
  if argument.description.len > 0:
    result["description"] = %argument.description

proc validatePromptArguments(arguments: seq[McpPromptArgument]): seq[McpPromptArgument] =
  for argument in arguments:
    if argument.name.len == 0:
      raise invalidPrompt("prompt argument name must not be empty")
    for existing in result:
      if existing.name == argument.name:
        raise invalidPrompt("duplicate prompt argument: " & argument.name)
    result.add argument

proc newMcpPrompt*(name: string, handler: McpPromptHandler, title = "",
                   description = "", arguments: seq[McpPromptArgument] = @[],
                   icons: JsonNode = nil): McpPrompt =
  if name.len == 0:
    raise invalidPrompt("prompt name must not be empty")
  if handler.isNil:
    raise invalidPrompt("prompt handler must not be nil")
  validatePromptPresentation(icons)
  McpPrompt(name: name, title: title, description: description, icons: icons,
    arguments: validatePromptArguments(arguments), handler: handler,
    completions: initTable[string, McpPromptCompletionHandler]())

proc newMcpPrompt*(name: string, handler: McpPromptSingleHandler, title = "",
                   description = "", arguments: seq[McpPromptArgument] = @[],
                   icons: JsonNode = nil): McpPrompt =
  if handler.isNil:
    raise invalidPrompt("prompt handler must not be nil")
  newMcpPrompt(name,
    proc (promptArguments: McpPromptArguments, context: McpContext):
        Future[seq[McpPromptMessage]] {.async.} =
      @[(await handler(promptArguments, context))],
    title, description, arguments, icons)

proc newMcpPrompt*(name: string, handler: McpSyncPromptHandler, title = "",
                   description = "", arguments: seq[McpPromptArgument] = @[],
                   icons: JsonNode = nil): McpPrompt =
  if handler.isNil:
    raise invalidPrompt("prompt handler must not be nil")
  newMcpPrompt(name,
    proc (promptArguments: McpPromptArguments, context: McpContext):
        Future[seq[McpPromptMessage]] {.async.} =
      handler(promptArguments, context),
    title, description, arguments, icons)

proc newMcpPrompt*(name: string, handler: McpSyncPromptSingleHandler,
                   title = "", description = "",
                   arguments: seq[McpPromptArgument] = @[],
                   icons: JsonNode = nil): McpPrompt =
  if handler.isNil:
    raise invalidPrompt("prompt handler must not be nil")
  newMcpPrompt(name,
    proc (promptArguments: McpPromptArguments, context: McpContext):
        Future[seq[McpPromptMessage]] {.async.} =
      @[handler(promptArguments, context)],
    title, description, arguments, icons)

proc newMcpPrompt*(name, description: string,
                   arguments: seq[McpPromptArgument],
                   handler: McpPromptHandler, title = "",
                   icons: JsonNode = nil): McpPrompt =
  newMcpPrompt(name, handler, title, description, arguments, icons)

proc newMcpPrompt*(name, description: string,
                   arguments: seq[McpPromptArgument],
                   handler: McpSyncPromptHandler, title = "",
                   icons: JsonNode = nil): McpPrompt =
  newMcpPrompt(name, handler, title, description, arguments, icons)

template mcpPrompt*(name: string, handler: untyped, title = "",
                    description = "", arguments: seq[McpPromptArgument] = @[],
                    icons: JsonNode = nil): McpPrompt =
  ## Concise prompt declaration; message escaping remains explicit in handlers.
  newMcpPrompt(name, handler, title, description, arguments, icons)

proc promptHasArgument(prompt: McpPrompt, name: string): bool =
  for argument in prompt.arguments:
    if argument.name == name: return true
  false

proc addCompletion*(prompt: var McpPrompt, argument: string,
                    handler: McpPromptCompletionHandler) =
  if argument.len == 0:
    raise invalidPrompt("prompt completion argument must not be empty")
  if not prompt.promptHasArgument(argument):
    raise invalidPrompt("unknown prompt argument: " & argument)
  if handler.isNil:
    raise invalidPrompt("prompt completion handler must not be nil")
  prompt.completions[argument] = handler

proc addCompletion*(prompt: var McpPrompt, argument: string,
                    handler: McpSyncPromptCompletionHandler) =
  if handler.isNil:
    raise invalidPrompt("prompt completion handler must not be nil")
  prompt.addCompletion(argument,
    proc (completionArgument, prefix: string, context: McpContext):
        Future[seq[string]] {.async.} =
      handler(completionArgument, prefix, context))

proc completePromptArgument*(prompt: McpPrompt, argument, prefix: string,
                             context: McpContext):
                             Future[seq[string]] {.async.} =
  if argument.len == 0:
    raise invalidPrompt("prompt completion argument must not be empty")
  if not prompt.promptHasArgument(argument):
    raise invalidPrompt("unknown prompt argument: " & argument)
  if argument notin prompt.completions:
    return @[]
  await prompt.completions[argument](argument, prefix, context)

proc toJson*(prompt: McpPrompt): JsonNode =
  result = %*{"name": prompt.name}
  if prompt.title.len > 0: result["title"] = %prompt.title
  if prompt.description.len > 0: result["description"] = %prompt.description
  if not prompt.icons.isNil: result["icons"] = prompt.icons
  if prompt.arguments.len > 0:
    result["arguments"] = newJArray()
    for argument in prompt.arguments:
      result["arguments"].add promptArgumentJson(argument)

proc decodePromptArguments*(prompt: McpPrompt,
                            values: JsonNode): McpPromptArguments =
  if values.isNil or values.kind != JObject:
    raise newMcpError("prompts/get arguments must be an object")
  result = initTable[string, string]()
  for key, value in values.pairs:
    if value.kind != JString:
      raise newMcpError("prompt argument '" & key & "' must be a string")
    var known = false
    for argument in prompt.arguments:
      if argument.name == key:
        known = true
        break
    if not known:
      raise newMcpError("unknown prompt argument: " & key)
    result[key] = value.getStr
  for argument in prompt.arguments:
    if argument.required and argument.name notin result:
      raise newMcpError("missing required prompt argument: " & argument.name)

proc getPromptArgument*(arguments: McpPromptArguments, name: string,
                        required = true): string =
  if name notin arguments:
    if required:
      raise newMcpError("missing prompt argument: " & name)
    return ""
  arguments[name]

proc runPrompt*(prompt: McpPrompt, arguments: McpPromptArguments,
                context: McpContext): Future[seq[McpPromptMessage]] {.async.} =
  let messages = await prompt.handler(arguments, context)
  for message in messages:
    validatePromptContent(message.content)
  messages
