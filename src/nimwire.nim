## A small, current-spec MCP server framework for Nim.
##
## The first transport is stdio. The server speaks the stateless
## 2026-07-28 protocol revision: every request carries its own protocol
## metadata and there is no initialize/session handshake.

import std/[algorithm, asyncdispatch, json, macros, strutils]

const
  mcpProtocolVersion* = "2026-07-28"
  mcpJsonRpcVersion = "2.0"

type
  McpError* = object of CatchableError
    code*: int
    data*: JsonNode

  McpToolHandler* = proc (arguments: JsonNode): Future[McpToolResult] {.closure.}
  McpSyncToolHandler* = proc (arguments: JsonNode): McpToolResult {.closure.}

  McpTool* = object
    name*: string
    description*: string
    inputSchema*: JsonNode
    outputSchema*: JsonNode
    handler*: McpToolHandler

  McpToolResult* = object
    ## `content` is the protocol content array. Keeping it as JSON lets the
    ## framework carry new MCP content kinds without changing this API.
    content*: JsonNode
    structuredContent*: JsonNode
    isError*: bool

  McpServer* = ref object
    name*: string
    version*: string
    instructions*: string
    listTtlMs*: int
    listCacheScope*: string
    tools*: seq[McpTool]

proc mcpFailure(message: string, code = -32602,
                data: JsonNode = nil): ref McpError =
  result = newException(McpError, message)
  result.code = code
  result.data = data

proc requireObject(node: JsonNode, context: string): JsonNode =
  if node.isNil or node.kind != JObject:
    raise mcpFailure(context & " must be an object")
  node

proc requiredString(node: JsonNode, key, context: string): string =
  if key notin node or node[key].kind != JString or node[key].getStr.len == 0:
    raise mcpFailure(context & " requires a non-empty '" & key & "'")
  node[key].getStr

proc newMcpServer*(name, version: string, instructions = "",
                   listTtlMs = 0, listCacheScope = "private"): McpServer =
  if name.len == 0: raise mcpFailure("server name must not be empty")
  if version.len == 0: raise mcpFailure("server version must not be empty")
  if listTtlMs < 0: raise mcpFailure("listTtlMs must be at least 0")
  if listCacheScope notin ["public", "private"]:
    raise mcpFailure("listCacheScope must be public or private")
  McpServer(name: name, version: version, instructions: instructions,
    listTtlMs: listTtlMs, listCacheScope: listCacheScope)

proc newMcpTool*(name, description: string, inputSchema: JsonNode,
                 handler: McpToolHandler,
                 outputSchema: JsonNode = nil): McpTool =
  if name.len == 0: raise mcpFailure("tool name must not be empty")
  if description.len == 0: raise mcpFailure("tool description must not be empty")
  if inputSchema.isNil or inputSchema.kind != JObject:
    raise mcpFailure("tool inputSchema must be a JSON object")
  if handler.isNil: raise mcpFailure("tool handler must not be nil")
  McpTool(name: name, description: description, inputSchema: inputSchema,
    outputSchema: outputSchema, handler: handler)

proc newMcpTool*(name, description: string, inputSchema: JsonNode,
                 handler: McpSyncToolHandler,
                 outputSchema: JsonNode = nil): McpTool =
  if handler.isNil: raise mcpFailure("tool handler must not be nil")
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
  if server.isNil: raise mcpFailure("server must not be nil")
  for current in server.tools:
    if current.name == tool.name:
      raise mcpFailure("duplicate tool name: " & tool.name)
  server.tools.add tool

proc textResult*(text: string, isError = false): McpToolResult =
  result.content = newJArray()
  result.content.add %*{"type": "text", "text": text}
  result.isError = isError

proc jsonResult*(value: JsonNode, isError = false): McpToolResult =
  result = textResult(if value.isNil: "null" else: $value, isError)
  result.structuredContent = if value.isNil: newJNull() else: value

proc serverMeta(server: McpServer): JsonNode =
  %*{"io.modelcontextprotocol/serverInfo": {
    "name": server.name,
    "version": server.version
  }}

proc resultObject(server: McpServer): JsonNode =
  result = %*{"resultType": "complete"}
  result["_meta"] = serverMeta(server)

proc response(id, value: JsonNode): JsonNode =
  %*{"jsonrpc": mcpJsonRpcVersion, "id": id, "result": value}

proc errorResponse(id: JsonNode, code: int, message: string,
                   data: JsonNode = nil): JsonNode =
  result = %*{"jsonrpc": mcpJsonRpcVersion, "id": id,
    "error": {"code": code, "message": message}}
  if not data.isNil:
    result["error"]["data"] = data

proc validateRequest(request: JsonNode): tuple[id: JsonNode, params: JsonNode] =
  if request.isNil or request.kind != JObject:
    raise mcpFailure("invalid JSON-RPC request")
  if "jsonrpc" notin request or request["jsonrpc"].kind != JString or
      request["jsonrpc"].getStr != mcpJsonRpcVersion:
    raise mcpFailure("invalid JSON-RPC request")
  if "method" notin request or request["method"].kind != JString:
    raise mcpFailure("invalid JSON-RPC request")
  if "id" notin request or request["id"].kind notin {JString, JInt}:
    raise mcpFailure("request id must be a string or integer")
  if "params" notin request or request["params"].kind != JObject:
    raise mcpFailure("request params must be an object")
  result.id = request["id"]
  result.params = request["params"]

proc validateMeta(params: JsonNode) =
  if "_meta" notin params or params["_meta"].kind != JObject:
    raise mcpFailure("request params require _meta")
  let meta = params["_meta"]
  let versionNode = meta.getOrDefault(
    "io.modelcontextprotocol/protocolVersion")
  if versionNode.isNil or versionNode.kind != JString or
      versionNode.getStr != mcpProtocolVersion:
    let version = if versionNode.isNil or versionNode.kind == JNull:
      "missing"
    else:
      versionNode.getStr
    let e = mcpFailure("unsupported MCP protocol version: " & version,
      -32022, %*{"supportedVersions": [mcpProtocolVersion]})
    raise e
  if "io.modelcontextprotocol/clientCapabilities" notin meta or
      meta["io.modelcontextprotocol/clientCapabilities"].kind != JObject:
    raise mcpFailure("request _meta requires clientCapabilities")

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
    raise mcpFailure("unknown tool: " & name)
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

proc serveStdio*(server: McpServer) =
  ## Run a newline-delimited JSON-RPC server over stdin/stdout.
  if server.isNil: raise mcpFailure("server must not be nil")
  while not endOfFile(stdin):
    let line = stdin.readLine()
    if line.strip.len == 0: continue
    var request: JsonNode
    try:
      request = parseJson(line)
    except CatchableError:
      stdout.writeLine($errorResponse(newJNull(), -32700, "Parse error"))
      flushFile(stdout)
      continue
    let output = server.handleJson(request)
    if not output.isNil:
      stdout.writeLine($output)
      flushFile(stdout)
