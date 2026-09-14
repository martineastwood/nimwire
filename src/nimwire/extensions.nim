## Generic, opt-in extension registry and dispatch.

import std/[asyncdispatch, json]

import ./core
import ./context
import ./schema

type
  McpExtensionMethodHandler* = proc (params: JsonNode,
                                     context: McpContext): Future[McpWireResult] {.closure.}

  McpExtensionMethod* = object
    name*: string
    handler*: McpExtensionMethodHandler
    inputSchema*: JsonNode
    outputSchema*: JsonNode
    metadata*: JsonNode
    transportRules*: JsonNode

  McpExtension* = ref object
    name*: string
    capabilities*: JsonNode
    metadata*: JsonNode
    methods*: seq[McpExtensionMethod]
    requiresClientCapability*: bool

  McpExtensionRegistry* = ref object
    drafts: seq[McpExtension]
    finalized: seq[McpExtension]

proc copyObject(node: JsonNode): JsonNode =
  result = newJObject()
  if node.isNil or node.kind != JObject: return
  for key, value in node.pairs:
    result[key] = value

proc validExtensionName(name: string): bool =
  if name.len == 0 or '/' notin name: return false
  for character in name:
    if character notin {'a' .. 'z', 'A' .. 'Z', '0' .. '9', '.', '-', '_', '/'}:
      return false
  true

proc newMcpExtension*(name: string, capabilities: JsonNode = nil,
                      metadata: JsonNode = nil,
                      requiresClientCapability = false): McpExtension =
  if not validExtensionName(name):
    raise newMcpError("extension name must be fully qualified")
  if not capabilities.isNil and capabilities.kind != JObject:
    raise newMcpError("extension capabilities must be an object")
  if not metadata.isNil and metadata.kind != JObject:
    raise newMcpError("extension metadata must be an object")
  McpExtension(name: name,
    capabilities: if capabilities.isNil: newJObject() else: capabilities,
    metadata: if metadata.isNil: newJObject() else: metadata,
    requiresClientCapability: requiresClientCapability)

proc addExtensionMethod*(extension: McpExtension, name: string,
                         handler: McpExtensionMethodHandler,
                         inputSchema: JsonNode = nil,
                         outputSchema: JsonNode = nil,
                         metadata: JsonNode = nil,
                         transportRules: JsonNode = nil) =
  if extension.isNil: raise newMcpError("extension must not be nil")
  validateMethod(name)
  if handler.isNil: raise newMcpError("extension method handler must not be nil")
  if not inputSchema.isNil:
    discard requireJsonSchema(inputSchema, "extension inputSchema")
  if not outputSchema.isNil:
    discard requireJsonSchema(outputSchema, "extension outputSchema")
  if not metadata.isNil and metadata.kind != JObject:
    raise newMcpError("extension method metadata must be an object")
  if not transportRules.isNil and transportRules.kind != JObject:
    raise newMcpError("extension transport rules must be an object")
  for extensionMethod in extension.methods:
    if extensionMethod.name == name:
      raise newMcpError("duplicate extension method: " & name)
  extension.methods.add McpExtensionMethod(name: name, handler: handler,
    inputSchema: inputSchema, outputSchema: outputSchema,
    metadata: if metadata.isNil: newJObject() else: metadata,
    transportRules: if transportRules.isNil: newJObject() else: transportRules)

proc newMcpExtensionRegistry*(): McpExtensionRegistry =
  McpExtensionRegistry()

proc containsExtension(registry: McpExtensionRegistry, name: string): bool =
  for extension in registry.drafts:
    if extension.name == name: return true
  for extension in registry.finalized:
    if extension.name == name: return true
  false

proc registerExtension*(registry: McpExtensionRegistry,
                        extension: McpExtension) =
  if registry.isNil: raise newMcpError("extension registry must not be nil")
  if extension.isNil: raise newMcpError("extension must not be nil")
  if registry.containsExtension(extension.name):
    raise newMcpError("duplicate extension: " & extension.name)
  registry.drafts.add extension

proc finalizeExtension*(registry: McpExtensionRegistry, name: string) =
  if registry.isNil: raise newMcpError("extension registry must not be nil")
  for index, extension in registry.drafts:
    if extension.name == name:
      registry.finalized.add extension
      registry.drafts.delete(index)
      return
  raise newMcpError("unknown extension draft: " & name)

proc hasFinalizedExtension*(registry: McpExtensionRegistry,
                            name: string): bool =
  if registry.isNil: return false
  for extension in registry.finalized:
    if extension.name == name: return true
  false

proc hasDraftExtension*(registry: McpExtensionRegistry, name: string): bool =
  if registry.isNil: return false
  for extension in registry.drafts:
    if extension.name == name: return true
  false

proc finalizedExtensions*(registry: McpExtensionRegistry): seq[McpExtension] =
  if not registry.isNil: result = registry.finalized

proc draftExtensions*(registry: McpExtensionRegistry): seq[McpExtension] =
  if not registry.isNil: result = registry.drafts

proc extensionCapabilities*(registry: McpExtensionRegistry): JsonNode =
  result = newJObject()
  if registry.isNil: return
  for extension in registry.finalized:
    result[extension.name] = copyObject(extension.capabilities)

proc addExtensionMetadata*(registry: McpExtensionRegistry, target: JsonNode) =
  if registry.isNil or target.isNil or target.kind != JObject: return
  for extension in registry.finalized:
    for key, value in extension.metadata.pairs:
      target[key] = value

proc clientSupportsExtension*(context: McpContext, name: string): bool =
  if context.isNil or context.metadata.clientCapabilities.fields.isNil or
      context.metadata.clientCapabilities.fields.kind != JObject or
      "extensions" notin context.metadata.clientCapabilities.fields:
    return false
  let extensions = context.metadata.clientCapabilities.fields["extensions"]
  extensions.kind == JObject and name in extensions

proc missingClientCapability(name: string): ref McpError =
  var required = newJObject()
  required[name] = newJObject()
  let extensions = newJObject()
  extensions["extensions"] = required
  var data = newJObject()
  data["requiredCapabilities"] = extensions
  newMcpError("Missing required client capability: " & name,
    mcpMissingRequiredClientCapabilityCode,
    data)

proc requireClientExtension*(context: McpContext, name: string) =
  if not context.clientSupportsExtension(name):
    raise missingClientCapability(name)

proc findExtensionMethod(registry: McpExtensionRegistry, name: string):
    tuple[extension: McpExtension, extensionMethod: McpExtensionMethod] =
  if registry.isNil: return
  for extension in registry.finalized:
    for extensionMethod in extension.methods:
      if extensionMethod.name == name:
        return (extension, extensionMethod)

proc dispatchExtensionAsync*(registry: McpExtensionRegistry,
                             request: McpRpcRequest,
                             context: McpContext): Future[McpWireResult] {.async.} =
  let found = registry.findExtensionMethod(request.methodName)
  if found.extension.isNil:
    raise newMcpError("Method not found: " & request.methodName,
      mcpMethodNotFoundCode)
  if found.extension.requiresClientCapability and
      not context.clientSupportsExtension(found.extension.name):
    context.requireClientExtension(found.extension.name)
  if not found.extensionMethod.inputSchema.isNil:
    validateJsonValue(found.extensionMethod.inputSchema, request.params.values,
      "extension '" & request.methodName & "' params")
  result = await found.extensionMethod.handler(request.params.values, context)
  if not found.extensionMethod.outputSchema.isNil:
    validateJsonValue(found.extensionMethod.outputSchema, result.fields,
      "extension '" & request.methodName & "' result")
