## Protocol primitives shared by nimwire servers and transports.

import std/json

const
  mcpProtocolVersion* = "2026-07-28"
  mcpJsonRpcVersion* = "2.0"

type
  McpError* = object of CatchableError
    code*: int
    data*: JsonNode

  McpToolResult* = object
    ## `content` is the protocol content array. Keeping it as JSON lets the
    ## framework carry new MCP content kinds without changing this API.
    content*: JsonNode
    structuredContent*: JsonNode
    isError*: bool

proc newMcpError*(message: string, code = -32602,
                  data: JsonNode = nil): ref McpError =
  result = newException(McpError, message)
  result.code = code
  result.data = data

proc requireObject*(node: JsonNode, context: string): JsonNode =
  if node.isNil or node.kind != JObject:
    raise newMcpError(context & " must be an object")
  node

proc requiredString*(node: JsonNode, key, context: string): string =
  if key notin node or node[key].kind != JString or node[key].getStr.len == 0:
    raise newMcpError(context & " requires a non-empty '" & key & "'")
  node[key].getStr

proc textResult*(text: string, isError = false): McpToolResult =
  result.content = newJArray()
  result.content.add %*{"type": "text", "text": text}
  result.isError = isError

proc jsonResult*(value: JsonNode, isError = false): McpToolResult =
  result = textResult(if value.isNil: "null" else: $value, isError)
  result.structuredContent = if value.isNil: newJNull() else: value

proc response*(id, value: JsonNode): JsonNode =
  %*{"jsonrpc": mcpJsonRpcVersion, "id": id, "result": value}

proc errorResponse*(id: JsonNode, code: int, message: string,
                    data: JsonNode = nil): JsonNode =
  result = %*{"jsonrpc": mcpJsonRpcVersion, "id": id,
    "error": {"code": code, "message": message}}
  if not data.isNil:
    result["error"]["data"] = data

proc validateRequest*(request: JsonNode): tuple[id: JsonNode, params: JsonNode] =
  if request.isNil or request.kind != JObject:
    raise newMcpError("invalid JSON-RPC request")
  if "jsonrpc" notin request or request["jsonrpc"].kind != JString or
      request["jsonrpc"].getStr != mcpJsonRpcVersion:
    raise newMcpError("invalid JSON-RPC request")
  if "method" notin request or request["method"].kind != JString:
    raise newMcpError("invalid JSON-RPC request")
  if "id" notin request or request["id"].kind notin {JString, JInt}:
    raise newMcpError("request id must be a string or integer")
  if "params" notin request or request["params"].kind != JObject:
    raise newMcpError("request params must be an object")
  result.id = request["id"]
  result.params = request["params"]

proc validateMeta*(params: JsonNode) =
  if "_meta" notin params or params["_meta"].kind != JObject:
    raise newMcpError("request params require _meta")
  let meta = params["_meta"]
  let versionNode = meta.getOrDefault(
    "io.modelcontextprotocol/protocolVersion")
  if versionNode.isNil or versionNode.kind != JString or
      versionNode.getStr != mcpProtocolVersion:
    let version = if versionNode.isNil or versionNode.kind == JNull:
      "missing"
    elif versionNode.kind == JString:
      versionNode.getStr
    else:
      $versionNode
    let e = newMcpError("unsupported MCP protocol version: " & version,
      -32022, %*{"supportedVersions": [mcpProtocolVersion]})
    raise e
  if "io.modelcontextprotocol/clientCapabilities" notin meta or
      meta["io.modelcontextprotocol/clientCapabilities"].kind != JObject:
    raise newMcpError("request _meta requires clientCapabilities")
