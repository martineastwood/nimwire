## Helpers for exercising nimwire servers without a transport process.

import std/json

import ./core
import ./server

proc modernRequest*(id: int, methodName: string,
                    params: JsonNode = newJObject()): JsonNode =
  var body = if params.isNil: newJObject() else: params
  body["_meta"] = %*{
    "io.modelcontextprotocol/protocolVersion": mcpProtocolVersion,
    "io.modelcontextprotocol/clientCapabilities": {}
  }
  %*{"jsonrpc": mcpJsonRpcVersion, "id": id, "method": methodName,
    "params": body}

proc sendRequest*(server: McpServer, request: JsonNode): JsonNode =
  server.handleJson(request)
