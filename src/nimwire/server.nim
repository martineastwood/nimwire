## MCP server registry and typed feature dispatch.

import std/[algorithm, asyncdispatch, base64, json, macros, options, strutils]

import ./core
import ./schema

type
  McpToolHandler* = proc (arguments: JsonNode): Future[McpToolResult] {.closure.}
  McpSyncToolHandler* = proc (arguments: JsonNode): McpToolResult {.closure.}

  McpTool* = object
    name*: string
    description*: string
    inputSchema*: JsonNode
    outputSchema*: JsonNode
    title*: string
    icons*: JsonNode
    annotations*: JsonNode
    handler*: McpToolHandler

  McpServer* = ref object
    name*: string
    version*: string
    instructions*: string
    listTtlMs*: int
    listCacheScope*: string
    listPageSize*: int
    toolsListChanged*: bool
    tools*: seq[McpTool]

proc newMcpServer*(name, version: string, instructions = "",
                   listTtlMs = 0, listCacheScope = "private",
                   listPageSize = 0): McpServer =
  if name.len == 0: raise newMcpError("server name must not be empty")
  if version.len == 0: raise newMcpError("server version must not be empty")
  if listTtlMs < 0: raise newMcpError("listTtlMs must be at least 0")
  if listCacheScope notin ["public", "private"]:
    raise newMcpError("listCacheScope must be public or private")
  if listPageSize < 0: raise newMcpError("listPageSize must be at least 0")
  McpServer(name: name, version: version, instructions: instructions,
    listTtlMs: listTtlMs, listCacheScope: listCacheScope,
    listPageSize: listPageSize)

proc newMcpTool*(name, description: string, inputSchema: JsonNode,
                 handler: McpToolHandler,
                 outputSchema: JsonNode = nil, title = "",
                 icons: JsonNode = nil, annotations: JsonNode = nil): McpTool =
  validateToolName(name)
  if description.len == 0: raise newMcpError("tool description must not be empty")
  discard requireJsonSchema(inputSchema, "tool inputSchema")
  if not outputSchema.isNil:
    discard requireJsonSchema(outputSchema, "tool outputSchema")
  discard mcpHeaderBindings(inputSchema)
  validateToolPresentation(icons, annotations)
  if handler.isNil: raise newMcpError("tool handler must not be nil")
  McpTool(name: name, description: description, inputSchema: inputSchema,
    outputSchema: outputSchema, title: title, icons: icons,
    annotations: annotations, handler: handler)

proc newMcpTool*(name, description: string, inputSchema: JsonNode,
                 handler: McpSyncToolHandler,
                 outputSchema: JsonNode = nil, title = "",
                 icons: JsonNode = nil, annotations: JsonNode = nil): McpTool =
  if handler.isNil: raise newMcpError("tool handler must not be nil")
  newMcpTool(name, description, inputSchema,
    proc (arguments: JsonNode): Future[McpToolResult] {.async.} =
      handler(arguments), outputSchema, title, icons, annotations)

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

proc markToolsChanged*(server: McpServer) =
  if server.isNil: raise newMcpError("server must not be nil")
  server.toolsListChanged = true

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
  if server.instructions.len > 0:
    fields["instructions"] = %server.instructions
  newMcpResult(mcpComplete, fields)

proc findTool*(server: McpServer, name: string): int =
  for i, tool in server.tools:
    if tool.name == name: return i
  -1

proc callTool(server: McpServer, params: McpParams): Future[McpResult] {.async.} =
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
  let output = await server.tools[index].handler(arguments)
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

proc dispatchAsync*(server: McpServer,
                    request: McpRpcRequest): Future[McpResult] {.async.} =
  case request.methodName
  of "server/discover":
    result = server.discover()
  of "ping":
    result = server.resultObject()
  of "tools/list":
    result = server.listTools(request.params)
  of "tools/call":
    result = await server.callTool(request.params)
  else:
    raise newMcpError("Method not found: " & request.methodName,
      mcpMethodNotFoundCode)

proc handleMessageAsync*(server: McpServer,
                         message: McpJsonRpcMessage):
                         Future[Option[McpJsonRpcMessage]] {.async.} =
  case message.kind
  of mcpRequestMessage, mcpNotificationMessage:
    let request = message.request
    try:
      let value = await server.dispatchAsync(request)
      if request.kind == mcpNotification:
        return none(McpJsonRpcMessage)
      return some(successResponse(request.id, value))
    except McpError as error:
      if request.kind == mcpNotification:
        return none(McpJsonRpcMessage)
      return some(errorResponse(request.id, error.code, error.msg, error.data))
    except CatchableError as error:
      if request.kind == mcpNotification:
        return none(McpJsonRpcMessage)
      return some(errorResponse(request.id, mcpInternalErrorCode, error.msg))
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
  try:
    let message = parseMcpMessage(request)
    let output = await server.handleMessageAsync(message)
    if output.isNone:
      return nil
    return toJson(output.get)
  except McpError as error:
    if isNotification:
      return nil
    return toJson(errorResponse(requestIdOrNull(request), error.code,
      error.msg, error.data))
  except CatchableError as error:
    if isNotification:
      return nil
    return toJson(errorResponse(requestIdOrNull(request), mcpInternalErrorCode,
      error.msg))

proc handleJson*(server: McpServer, request: JsonNode): JsonNode =
  waitFor server.handleJsonAsync(request)
