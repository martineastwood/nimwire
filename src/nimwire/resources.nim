## Resource definitions, URI templates, contents, and safe file helpers.

import std/[asyncdispatch, base64, json, os, tables, strutils, unicode, uri]

import ./context
import ./core
import ./prompts

type
  McpResourceContentKind* = enum
    mcpResourceText
    mcpResourceBlob

  McpResourceContent* = object
    uri*: string
    mimeType*: string
    case kind*: McpResourceContentKind
    of mcpResourceText:
      text*: string
    of mcpResourceBlob:
      blob*: string

  McpResourceReadHandler* = proc (uri: string,
                                 context: McpContext):
                                 Future[seq[McpResourceContent]] {.closure.}
  McpResourceSingleReadHandler* = proc (uri: string,
                                        context: McpContext):
                                        Future[McpResourceContent] {.closure.}
  McpSyncResourceReadHandler* = proc (uri: string,
                                      context: McpContext):
                                      seq[McpResourceContent] {.closure.}
  McpSyncResourceSingleReadHandler* = proc (uri: string,
                                             context: McpContext):
                                             McpResourceContent {.closure.}

  McpResourceCompletionHandler* = proc (argument, prefix: string,
                                        context: McpContext):
                                        Future[seq[string]] {.closure.}
  McpSyncResourceCompletionHandler* = proc (argument, prefix: string,
                                             context: McpContext):
                                             seq[string] {.closure.}

  McpResource* = object
    uri*: string
    name*: string
    title*: string
    description*: string
    icons*: JsonNode
    mimeType*: string
    size*: int64
    ## Untrusted caller-facing metadata; never use it as an authorization policy.
    annotations*: JsonNode
    contents*: seq[McpResourceContent]
    readHandler: McpResourceReadHandler

  McpResourceTemplate* = object
    uriTemplate*: string
    name*: string
    title*: string
    description*: string
    icons*: JsonNode
    mimeType*: string
    ## Untrusted caller-facing metadata; never use it as an authorization policy.
    annotations*: JsonNode
    readHandler: McpResourceTemplateReadHandler
    completionHandlers: Table[string, McpResourceCompletionHandler]

  McpResourceTemplateReadHandler* = proc (uri: string, arguments: JsonNode,
                                          context: McpContext):
                                          Future[seq[McpResourceContent]] {.closure.}
  McpResourceTemplateSingleReadHandler* = proc (uri: string,
                                                arguments: JsonNode,
                                                context: McpContext):
                                                Future[McpResourceContent] {.closure.}
  McpSyncResourceTemplateReadHandler* = proc (uri: string, arguments: JsonNode,
                                               context: McpContext):
                                               seq[McpResourceContent] {.closure.}
  McpSyncResourceTemplateSingleReadHandler* = proc (uri: string,
                                                     arguments: JsonNode,
                                                     context: McpContext):
                                                     McpResourceContent {.closure.}

proc invalidResource(message: string): ref McpError =
  newMcpError(message)

proc validateResourceUri*(uriValue: string, context = "resource") =
  if uriValue.len == 0:
    raise invalidResource(context & " URI must not be empty")
  for character in uriValue:
    if character.ord < 32 or character in {' ', '\t', '\r', '\n'}:
      raise invalidResource(context & " URI contains invalid whitespace")
  try:
    if parseUri(uriValue).scheme.len == 0:
      raise invalidResource(context & " URI must include a scheme")
  except McpError:
    raise
  except CatchableError as error:
    raise invalidResource(context & " URI is invalid: " & error.msg)

proc validatePresentation(icons, annotations: JsonNode, context: string) =
  if not icons.isNil:
    if icons.kind != JArray:
      raise invalidResource(context & " icons must be an array")
    for icon in icons.items:
      if icon.kind != JObject or "src" notin icon or
          icon["src"].kind != JString or icon["src"].getStr.len == 0:
        raise invalidResource(context & " icons require a non-empty src")
      if "mimeType" in icon and icon["mimeType"].kind != JString:
        raise invalidResource(context & " icon mimeType must be a string")
      if "sizes" in icon:
        if icon["sizes"].kind != JArray:
          raise invalidResource(context & " icon sizes must be an array")
        for size in icon["sizes"].items:
          if size.kind != JString or size.getStr.len == 0:
            raise invalidResource(context & " icon sizes must be strings")
  if not annotations.isNil and annotations.kind != JObject:
    raise invalidResource(context & " annotations must be an object")

proc validateBase64(blob: string) =
  try:
    discard decode(blob)
  except CatchableError as error:
    raise invalidResource("resource blob is not valid base64: " & error.msg)

proc resourceText*(uri, text: string, mimeType = ""): McpResourceContent =
  validateResourceUri(uri, "resource content")
  if validateUtf8(text) >= 0:
    raise invalidResource("resource text must be valid UTF-8")
  McpResourceContent(kind: mcpResourceText, uri: uri, mimeType: mimeType,
    text: text)

proc resourceBlob*(uri, blob: string, mimeType = ""): McpResourceContent =
  validateResourceUri(uri, "resource content")
  validateBase64(blob)
  McpResourceContent(kind: mcpResourceBlob, uri: uri, mimeType: mimeType,
    blob: blob)

proc resourceBytes*(uri, data: string, mimeType = ""): McpResourceContent =
  resourceBlob(uri, encode(data), mimeType)

proc newMcpResource*(uri, name: string, contents: seq[McpResourceContent],
                     title = "", description = "", icons: JsonNode = nil,
                     mimeType = "", size: int64 = -1,
                     annotations: JsonNode = nil): McpResource =
  validateResourceUri(uri, "resource")
  if name.len == 0:
    raise invalidResource("resource name must not be empty")
  if size < -1:
    raise invalidResource("resource size must be non-negative")
  validatePresentation(icons, annotations, "resource")
  for content in contents:
    validateResourceUri(content.uri, "resource content")
  let declaredMimeType = if mimeType.len > 0: mimeType elif contents.len > 0:
    contents[0].mimeType
  else:
    ""
  result = McpResource(uri: uri, name: name, title: title,
    description: description, icons: icons, mimeType: declaredMimeType, size: size,
    annotations: annotations, contents: contents)

proc newMcpResource*(uri, name: string, content: McpResourceContent,
                     title = "", description = "", icons: JsonNode = nil,
                     mimeType = "", size: int64 = -1,
                     annotations: JsonNode = nil): McpResource =
  newMcpResource(uri, name, @[content], title, description, icons, mimeType,
    size, annotations)

proc newMcpResource*(uri, name: string, handler: McpResourceReadHandler,
                     title = "", description = "", icons: JsonNode = nil,
                     mimeType = "", size: int64 = -1,
                     annotations: JsonNode = nil): McpResource =
  if handler.isNil:
    raise invalidResource("resource read handler must not be nil")
  validateResourceUri(uri, "resource")
  if name.len == 0:
    raise invalidResource("resource name must not be empty")
  if size < -1:
    raise invalidResource("resource size must be non-negative")
  validatePresentation(icons, annotations, "resource")
  McpResource(uri: uri, name: name, title: title, description: description,
    icons: icons, mimeType: mimeType, size: size, annotations: annotations,
    readHandler: handler)

proc newMcpResource*(uri, name: string,
                     handler: McpResourceSingleReadHandler,
                     title = "", description = "", icons: JsonNode = nil,
                     mimeType = "", size: int64 = -1,
                     annotations: JsonNode = nil): McpResource =
  if handler.isNil:
    raise invalidResource("resource read handler must not be nil")
  newMcpResource(uri, name,
    proc (requestedUri: string, context: McpContext):
        Future[seq[McpResourceContent]] {.async.} =
      @[(await handler(requestedUri, context))],
    title, description, icons, mimeType, size, annotations)

proc newMcpResource*(uri, name: string, handler: McpSyncResourceReadHandler,
                     title = "", description = "", icons: JsonNode = nil,
                     mimeType = "", size: int64 = -1,
                     annotations: JsonNode = nil): McpResource =
  if handler.isNil:
    raise invalidResource("resource read handler must not be nil")
  newMcpResource(uri, name,
    proc (requestedUri: string, context: McpContext):
        Future[seq[McpResourceContent]] {.async.} =
      handler(requestedUri, context),
    title, description, icons, mimeType, size, annotations)

proc newMcpResource*(uri, name: string,
                     handler: McpSyncResourceSingleReadHandler,
                     title = "", description = "", icons: JsonNode = nil,
                     mimeType = "", size: int64 = -1,
                     annotations: JsonNode = nil): McpResource =
  if handler.isNil:
    raise invalidResource("resource read handler must not be nil")
  newMcpResource(uri, name,
    proc (requestedUri: string, context: McpContext):
        Future[seq[McpResourceContent]] {.async.} =
      @[handler(requestedUri, context)],
    title, description, icons, mimeType, size, annotations)

proc templateVariableName(expression: string): string =
  result = expression
  if result.len > 0 and result[0] in {'+', '#', '.', '/', ';', '?', '&'}:
    result = result[1 .. ^1]
  if result.endsWith("*"): result.setLen(result.len - 1)
  if result.len == 0:
    raise invalidResource("resource URI template variable must not be empty")
  for character in result:
    if not ((character >= 'a' and character <= 'z') or
            (character >= 'A' and character <= 'Z') or
            (character >= '0' and character <= '9') or
            character in {'_', '.', '-'}):
      raise invalidResource("resource URI template contains an invalid variable")
  return result

proc templateExpressions(uriTemplate: string): seq[(int, int, string)] =
  var index = 0
  while index < uriTemplate.len:
    if uriTemplate[index] == '}':
      raise invalidResource("resource URI template has an unmatched '}'")
    if uriTemplate[index] != '{':
      inc index
      continue
    let close = uriTemplate.find('}', index + 1)
    if close < 0:
      raise invalidResource("resource URI template has an unmatched '{'")
    let expression = uriTemplate[index + 1 ..< close]
    if expression.len == 0 or expression.contains('{'):
      raise invalidResource("resource URI template expression must not be empty")
    if expression.count(',') > 0:
      raise invalidResource("resource URI template supports one variable per expression")
    result.add (index, close, templateVariableName(expression))
    index = close + 1

proc validateUriTemplate*(uriTemplate: string) =
  if uriTemplate.len == 0:
    raise invalidResource("resource URI template must not be empty")
  for character in uriTemplate:
    if character.ord < 32 or character in {' ', '\t', '\r', '\n'}:
      raise invalidResource("resource URI template contains invalid whitespace")
  for expression in templateExpressions(uriTemplate):
    discard expression
  var literal = uriTemplate
  for character in ['{', '}']:
    literal = literal.replace($character, "")
  try:
    if parseUri(literal).scheme.len == 0:
      raise invalidResource("resource URI template must include a scheme")
  except McpError:
    raise
  except CatchableError as error:
    raise invalidResource("resource URI template is invalid: " & error.msg)

proc resourceTemplateVariables*(uriTemplate: string): seq[string] =
  for expression in templateExpressions(uriTemplate):
    if expression[2] notin result:
      result.add expression[2]

proc startsAt(value, prefix: string, position: int): bool =
  position >= 0 and position + prefix.len <= value.len and
    value[position ..< position + prefix.len] == prefix

proc newMcpResourceTemplate*(uriTemplate, name: string,
                            handler: McpResourceTemplateReadHandler,
                            title = "", description = "",
                            icons: JsonNode = nil, mimeType = "",
    annotations: JsonNode = nil): McpResourceTemplate =
  validateUriTemplate(uriTemplate)
  if name.len == 0:
    raise invalidResource("resource template name must not be empty")
  if handler.isNil:
    raise invalidResource("resource template read handler must not be nil")
  validatePresentation(icons, annotations, "resource template")
  McpResourceTemplate(uriTemplate: uriTemplate, name: name, title: title,
    description: description, icons: icons, mimeType: mimeType,
    annotations: annotations, readHandler: handler,
    completionHandlers: initTable[string, McpResourceCompletionHandler]())

proc toJson*(resource: McpResource): JsonNode =
  result = %*{"uri": resource.uri, "name": resource.name}
  if resource.title.len > 0: result["title"] = %resource.title
  if resource.description.len > 0: result["description"] = %resource.description
  if not resource.icons.isNil: result["icons"] = resource.icons
  if resource.mimeType.len > 0: result["mimeType"] = %resource.mimeType
  if resource.size >= 0: result["size"] = %resource.size
  if not resource.annotations.isNil: result["annotations"] = resource.annotations

proc toJson*(resourceTemplate: McpResourceTemplate): JsonNode =
  result = %*{"uriTemplate": resourceTemplate.uriTemplate,
    "name": resourceTemplate.name}
  if resourceTemplate.title.len > 0:
    result["title"] = %resourceTemplate.title
  if resourceTemplate.description.len > 0:
    result["description"] = %resourceTemplate.description
  if not resourceTemplate.icons.isNil:
    result["icons"] = resourceTemplate.icons
  if resourceTemplate.mimeType.len > 0:
    result["mimeType"] = %resourceTemplate.mimeType
  if not resourceTemplate.annotations.isNil:
    result["annotations"] = resourceTemplate.annotations

proc newMcpResourceTemplate*(uriTemplate, name: string,
                            handler: McpResourceTemplateSingleReadHandler,
                            title = "", description = "",
                            icons: JsonNode = nil, mimeType = "",
                            annotations: JsonNode = nil): McpResourceTemplate =
  if handler.isNil:
    raise invalidResource("resource template read handler must not be nil")
  newMcpResourceTemplate(uriTemplate, name,
    proc (uri: string, arguments: JsonNode, context: McpContext):
        Future[seq[McpResourceContent]] {.async.} =
      @[(await handler(uri, arguments, context))],
    title, description, icons, mimeType, annotations)

proc newMcpResourceTemplate*(uriTemplate, name: string,
                            handler: McpSyncResourceTemplateReadHandler,
                            title = "", description = "",
                            icons: JsonNode = nil, mimeType = "",
                            annotations: JsonNode = nil): McpResourceTemplate =
  if handler.isNil:
    raise invalidResource("resource template read handler must not be nil")
  newMcpResourceTemplate(uriTemplate, name,
    proc (uri: string, arguments: JsonNode, context: McpContext):
        Future[seq[McpResourceContent]] {.async.} =
      handler(uri, arguments, context),
    title, description, icons, mimeType, annotations)

proc newMcpResourceTemplate*(uriTemplate, name: string,
                            handler: McpSyncResourceTemplateSingleReadHandler,
                            title = "", description = "",
                            icons: JsonNode = nil, mimeType = "",
                            annotations: JsonNode = nil): McpResourceTemplate =
  if handler.isNil:
    raise invalidResource("resource template read handler must not be nil")
  newMcpResourceTemplate(uriTemplate, name,
    proc (uri: string, arguments: JsonNode, context: McpContext):
        Future[seq[McpResourceContent]] {.async.} =
      @[handler(uri, arguments, context)],
    title, description, icons, mimeType, annotations)

template mcpResource*(uri, name: string, value: untyped, title = "",
                      description = "", icons: JsonNode = nil,
                      mimeType = "", size: int64 = -1,
                      annotations: JsonNode = nil): McpResource =
  ## Concise static or handler-backed resource declaration.
  newMcpResource(uri, name, value, title, description, icons, mimeType, size,
    annotations)

template mcpResourceTemplate*(uriTemplate, name: string, handler: untyped,
                              title = "", description = "",
                              icons: JsonNode = nil, mimeType = "",
                              annotations: JsonNode = nil): McpResourceTemplate =
  ## Concise URI-template resource declaration.
  newMcpResourceTemplate(uriTemplate, name, handler, title, description, icons,
    mimeType, annotations)

proc addCompletion*(resourceTemplate: var McpResourceTemplate, argument: string,
                    handler: McpResourceCompletionHandler) =
  if argument notin resourceTemplateVariables(resourceTemplate.uriTemplate):
    raise invalidResource("resource template has no argument named " & argument)
  if handler.isNil:
    raise invalidResource("resource completion handler must not be nil")
  resourceTemplate.completionHandlers[argument] = handler

proc addCompletion*(resourceTemplate: var McpResourceTemplate,
                    completion: McpCompletion) =
  resourceTemplate.addCompletion(completion.argument, completion.handler)

proc addCompletion*(resourceTemplate: var McpResourceTemplate, argument: string,
                    handler: McpSyncResourceCompletionHandler) =
  if handler.isNil:
    raise invalidResource("resource completion handler must not be nil")
  resourceTemplate.addCompletion(argument,
    proc (name, prefix: string, context: McpContext):
        Future[seq[string]] {.async.} =
      handler(name, prefix, context))

proc matchResourceTemplate*(resourceTemplate: McpResourceTemplate,
                            uriValue: string): JsonNode =
  let expressions = templateExpressions(resourceTemplate.uriTemplate)
  var uriPosition = 0
  var templatePosition = 0
  var expressionIndex = 0
  result = newJObject()
  while expressionIndex < expressions.len:
    let (open, close, variable) = expressions[expressionIndex]
    let literal = resourceTemplate.uriTemplate[templatePosition ..< open]
    if not startsAt(uriValue, literal, uriPosition): return nil
    uriPosition += literal.len
    let nextOpen = if expressionIndex + 1 < expressions.len:
      expressions[expressionIndex + 1][0]
    else:
      resourceTemplate.uriTemplate.len
    let literalAfter = if expressionIndex + 1 < expressions.len:
      resourceTemplate.uriTemplate[close + 1 ..< nextOpen]
    else:
      ""
    let endPosition = if literalAfter.len == 0:
      uriValue.len
    else:
      uriValue.find(literalAfter, uriPosition)
    if endPosition < uriPosition: return nil
    let encodedValue = uriValue[uriPosition ..< endPosition]
    result[variable] = %decodeUrl(encodedValue, false)
    uriPosition = endPosition
    templatePosition = close + 1
    inc expressionIndex
  let tail = if templatePosition < resourceTemplate.uriTemplate.len:
    resourceTemplate.uriTemplate[templatePosition .. ^1]
  else:
    ""
  if expressions.len == 0:
    return if uriValue == tail: result else: nil
  elif tail.len > 0:
    if not startsAt(uriValue, tail, uriPosition): return nil
    uriPosition += tail.len
  if uriPosition != uriValue.len: return nil

proc readResource*(resource: McpResource, uriValue: string,
                   context: McpContext): Future[seq[McpResourceContent]] {.async.} =
  if resource.readHandler.isNil:
    return resource.contents
  await resource.readHandler(uriValue, context)

proc readResourceTemplate*(resourceTemplate: McpResourceTemplate, uriValue: string,
                           arguments: JsonNode,
                           context: McpContext): Future[seq[McpResourceContent]] {.async.} =
  await resourceTemplate.readHandler(uriValue, arguments, context)

proc completeResourceTemplate*(resourceTemplate: McpResourceTemplate,
                               argument, prefix: string,
                               context: McpContext): Future[seq[string]] {.async.} =
  if argument notin resourceTemplate.completionHandlers:
    return @[]
  await resourceTemplate.completionHandlers[argument](argument, prefix, context)

proc resourceContentJson*(content: McpResourceContent,
                          defaultMimeType = ""): JsonNode =
  validateResourceUri(content.uri, "resource content")
  result = %*{"uri": content.uri}
  let mimeType = if content.mimeType.len > 0: content.mimeType else: defaultMimeType
  if mimeType.len > 0: result["mimeType"] = %mimeType
  case content.kind
  of mcpResourceText:
    if validateUtf8(content.text) >= 0:
      raise invalidResource("resource text must be valid UTF-8")
    result["text"] = %content.text
  of mcpResourceBlob:
    validateBase64(content.blob)
    result["blob"] = %content.blob

proc toJson*(content: McpResourceContent): JsonNode =
  resourceContentJson(content)

proc fileUri(path: string): string =
  "file://" & encodeUrl(path.replace(DirSep, '/'), false).replace("%2F", "/")

proc safeResourcePath*(root, path: string): string =
  if root.len == 0 or not dirExists(root):
    raise invalidResource("resource root must be an existing directory")
  if path.len == 0 or '\x00' in path:
    raise invalidResource("resource path must not be empty")
  let rootPath = expandFilename(root).normalizedPath
  var requested = if path.isAbsolute: path else: rootPath / path
  requested = requested.normalizedPath
  var probe = requested
  var suffix: seq[string]
  while probe.len > 0 and not fileExists(probe) and not dirExists(probe):
    let (parent, name) = probe.splitPath
    if parent == probe or name.len == 0: break
    suffix.add name
    probe = parent
  var real = if probe.len > 0 and (fileExists(probe) or dirExists(probe)):
    expandFilename(probe)
  else:
    requested
  for index in countdown(suffix.high, 0):
    real = real / suffix[index]
  let canonicalRoot = expandFilename(rootPath).normalizedPath
  if real != canonicalRoot and not real.startsWith(canonicalRoot & DirSep):
    raise invalidResource("resource path escapes its root")
  real

proc newFileResource*(root, relativePath: string, name = "", title = "",
                      description = "", mimeType = "", binary = false,
                      uriValue = "", icons: JsonNode = nil,
                      annotations: JsonNode = nil): McpResource =
  let path = safeResourcePath(root, relativePath)
  if not fileExists(path):
    raise invalidResource("resource file does not exist")
  let resourceUri = if uriValue.len > 0: uriValue else: fileUri(path)
  let resourceName = if name.len > 0: name else: path.lastPathPart
  let declaredMime = mimeType
  let handler: McpResourceReadHandler = proc (requestedUri: string,
      context: McpContext): Future[seq[McpResourceContent]] {.async.} =
    discard context
    let safePath = safeResourcePath(root, relativePath)
    let data = readFile(safePath)
    result = @[
      if binary: resourceBytes(requestedUri, data, declaredMime)
      else: resourceText(requestedUri, data, declaredMime)]
  newMcpResource(resourceUri, resourceName, handler, title, description,
    icons, declaredMime, getFileSize(path), annotations)

proc newFileResourceTemplate*(root, uriTemplate, name: string,
                              pathArgument = "path", title = "",
                              description = "", mimeType = "", binary = false,
                              icons: JsonNode = nil,
                              annotations: JsonNode = nil): McpResourceTemplate =
  if pathArgument notin resourceTemplateVariables(uriTemplate):
    raise invalidResource("file resource template has no path argument")
  let handler: McpResourceTemplateReadHandler = proc (uriValue: string,
      arguments: JsonNode, context: McpContext):
      Future[seq[McpResourceContent]] {.async.} =
    discard context
    if pathArgument notin arguments or
        arguments[pathArgument].kind != JString:
      raise newMcpError("resource template path argument must be a string")
    let path = safeResourcePath(root, arguments[pathArgument].getStr)
    if not fileExists(path):
      raise newMcpError("resource file does not exist")
    let data = readFile(path)
    result = @[
      if binary: resourceBytes(uriValue, data, mimeType)
      else: resourceText(uriValue, data, mimeType)]
  newMcpResourceTemplate(uriTemplate, name, handler, title, description,
    icons, mimeType, annotations)
