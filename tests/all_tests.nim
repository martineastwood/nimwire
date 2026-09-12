import std/[json, unittest]
import ../src/nimwire

suite "nimwire MCP server":
  let server = mcpServer("test-server", "1.0.0"):
    server.addTool mcpTool("echo", "Echo text", %*{
      "type": "object",
      "properties": {"text": {"type": "string"}},
      "required": ["text"]
    }, proc (args: JsonNode): McpToolResult =
      textResult(args["text"].getStr))

  test "uses the modern stateless discovery request":
    let response = server.handleJson(modernRequest(1, "server/discover"))
    check response["result"]["resultType"].getStr == "complete"
    check response["result"]["supportedVersions"][0].getStr ==
      mcpProtocolVersion
    check response["result"]["_meta"][
      "io.modelcontextprotocol/serverInfo"]["name"].getStr == "test-server"

  test "lists tools deterministically":
    let response = server.handleJson(modernRequest(2, "tools/list"))
    check response["result"]["tools"].len == 1
    check response["result"]["tools"][0]["name"].getStr == "echo"
    check response["result"]["ttlMs"].getInt == 0
    check response["result"]["cacheScope"].getStr == "private"

  test "calls a tool and returns MCP content":
    let response = server.handleJson(modernRequest(3, "tools/call", %*{
      "name": "echo",
      "arguments": {"text": "hello"}
    }))
    check response["result"]["resultType"].getStr == "complete"
    check response["result"]["content"][0]["type"].getStr == "text"
    check response["result"]["content"][0]["text"].getStr == "hello"
    check not response["result"]["isError"].getBool

  test "rejects unknown tools as invalid params":
    let response = server.handleJson(modernRequest(4, "tools/call", %*{
      "name": "missing",
      "arguments": {}
    }))
    check response["error"]["code"].getInt == -32602

  test "rejects a missing modern envelope":
    let response = server.handleJson(%*{
      "jsonrpc": "2.0", "id": 5, "method": "tools/list", "params": {}
    })
    check response["error"]["code"].getInt == -32602

  test "rejects a missing protocol version":
    var request = modernRequest(6, "tools/list")
    request["params"]["_meta"].delete("io.modelcontextprotocol/protocolVersion")
    let response = server.handleJson(request)
    check response["error"]["code"].getInt == -32022

  test "reports unsupported protocol versions with the MCP error code":
    var request = modernRequest(7, "tools/list")
    request["params"]["_meta"][
      "io.modelcontextprotocol/protocolVersion"] = %"2025-11-25"
    let response = server.handleJson(request)
    check response["error"]["code"].getInt == -32022
