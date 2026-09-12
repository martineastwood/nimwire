## MCP server registry and feature dispatch.

import std/[algorithm, asyncdispatch, json, macros]

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
    handler*: McpToolHandler

  McpServer* = ref object
    name*: string
    version*: string
    instructions*: string
    listTtlMs*: int
    listCacheScope*: string
    tools*: seq[McpTool]

proc newMcpServer*(name, version: string, instructions = "",
                   listTtlMs = 0, listCacheScope = "private"): McpServer =
  if name.len == 0: raise newMcpError("server name must not be empty")
  if version.len == 0: raise newMcpError("server version must not be empty")
  if listTtlMs < 0: raise newMcpError("listTtlMs must be at least 0")
  if listCacheScope notin ["public", "private"]:
    raise newMcpError("listCacheScope must be public or private")
  McpServer(name: name, version: version, instructions: instructions,
    listTtlMs: listTtlMs, listCacheScope: listCacheScope)

proc newMcpTool*(name, description: string, inputSchema: JsonNode,
                 handler: McpToolHandler,
                 outputSchema: JsonNode = nil): McpTool =
  if name.len == 0: raise newMcpError("tool name must not be empty")
  if description.len == 0: raise newMcpError("tool description must not be empty")
  discard requireJsonSchema(inputSchema, "tool inputSchema")
  if handler.isNil: raise newMcpError("tool handler must not be nil")
  McpTool(name: name, description: description, inputSchema: inputSchema,
    outputSchema: outputSchema, handler: handler)

proc newMcpTool*(name, description: string, inputSchema: JsonNode,
                 handler: McpSyncToolHandler,
                 outputSchema: JsonNode = nil): McpTool =
  if handler.isNil: raise newMcpError("tool handler must not be nil")
  newMcpTool(name, description, inputSchema,
    proc (arguments: JsonNode): Future[McpToolResult] {.async.} =
      handler(arguments), outputSchema)

template mcpTool*(name, description: string, inputSchema: JsonNode,
                  handler: untyped): McpTool =
  ## Concise tool declaration that works with sync or async handlers.
  newMcpTool(name, description, inputSchema, handler)

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

proc serverMeta(server: McpServer): JsonNode =
  %*{"io.modelcontextprotocol/serverInfo": {
    "name": server.name,
    "version": server.version
  }}

proc resultObject(server: McpServer): JsonNode =
  result = %*{"resultType": "complete"}
  result["_meta"] = serverMeta(server)

proc toolJson(tool: McpTool): JsonNode =
  result = %*{"name": tool.name, "description": tool.description,
    "inputSchema": tool.inputSchema}
  if not tool.outputSchema.isNil:
    result["outputSchema"] = tool.outputSchema

proc listTools(server: McpServer): JsonNode =
  var tools = server.tools
  tools.sort(proc (a, b: McpTool): int = cmp(a.name, b.name))
  result = resultObject(server)
  result["tools"] = newJArray()
  for tool in tools:
    result["tools"].add toolJson(tool)
  result["ttlMs"] = %server.listTtlMs
  result["cacheScope"] = %server.listCacheScope

proc discover(server: McpServer): JsonNode =
  result = resultObject(server)
  result["supportedVersions"] = %*[mcpProtocolVersion]
  result["capabilities"] = %*{"tools": {"listChanged": false}}
  if server.instructions.len > 0:
    result["instructions"] = %server.instructions

proc findTool(server: McpServer, name: string): int =
  for i, tool in server.tools:
    if tool.name == name: return i
  -1

proc callTool(server: McpServer, params: JsonNode): Future[JsonNode] {.async.} =
  let name = requiredString(params, "name", "tools/call params")
  let arguments = if "arguments" in params:
    requireObject(params["arguments"], "tools/call arguments")
  else:
    newJObject()
  let index = server.findTool(name)
  if index < 0:
    raise newMcpError("unknown tool: " & name)
  let output = await server.tools[index].handler(arguments)
  result = resultObject(server)
  result["content"] = if output.content.isNil: newJArray() else: output.content
  result["isError"] = %output.isError
  if not output.structuredContent.isNil:
    result["structuredContent"] = output.structuredContent

proc handleJsonAsync*(server: McpServer, request: JsonNode): Future[JsonNode]
    {.async.} =
  ## Dispatch one modern MCP request. Notifications return nil.
  if request.isNil or request.kind != JObject:
    return errorResponse(newJNull(), -32600, "Invalid Request")
  let isNotification = "id" notin request
  var parsed: tuple[id: JsonNode, params: JsonNode]
  try:
    parsed = validateRequest(request)
    validateMeta(parsed.params)
  except McpError as e:
    return if isNotification: nil else:
      errorResponse(request.getOrDefault("id"), e.code, e.msg, e.data)
  except CatchableError as e:
    return if isNotification: nil else:
      errorResponse(request.getOrDefault("id"), -32600, e.msg)

  let methodName = request["method"].getStr
  try:
    case methodName
    of "server/discover":
      return if isNotification: nil else: response(parsed.id, server.discover())
    of "ping":
      var value = server.resultObject()
      return if isNotification: nil else: response(parsed.id, value)
    of "tools/list":
      return if isNotification: nil else: response(parsed.id, server.listTools())
    of "tools/call":
      let value = await server.callTool(parsed.params)
      return if isNotification: nil else: response(parsed.id, value)
    else:
      return if isNotification: nil else:
        errorResponse(parsed.id, -32601, "Method not found: " & methodName)
  except McpError as e:
    if isNotification: return nil
    return errorResponse(parsed.id, e.code, e.msg, e.data)
  except CatchableError as e:
    if isNotification: return nil
    return errorResponse(parsed.id, -32603, e.msg)

proc handleJson*(server: McpServer, request: JsonNode): JsonNode =
  waitFor server.handleJsonAsync(request)
