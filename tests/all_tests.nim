import std/[asyncdispatch, json, sequtils, strutils, unittest]
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

  test "decodes requests and metadata into typed values":
    let request = %*{
      "jsonrpc": "2.0",
      "id": "typed-request",
      "method": "ping",
      "params": {
        "customParam": true,
        "_meta": {
          "io.modelcontextprotocol/protocolVersion": mcpProtocolVersion,
          "io.modelcontextprotocol/clientInfo": {
            "name": "test-client",
            "version": "2.0.0",
            "com.example/clientField": "preserved"
          },
          "io.modelcontextprotocol/clientCapabilities": {
            "tools": {"listChanged": true}
          },
          "io.modelcontextprotocol/traceContext": {
            "traceparent": "00-abc-def-01",
            "vendor": {"sampled": true}
          },
          "io.modelcontextprotocol/logLevel": "debug",
          "com.example/extension": {"enabled": true}
        }
      },
      "com.example/requestExtension": "preserved"
    }
    let parsed = parseMcpMessage(request)
    check parsed.kind == mcpRequestMessage
    check parsed.request.kind == mcpRequest
    check parsed.request.id.kind == mcpStringId
    check parsed.request.id.stringValue == "typed-request"
    check parsed.request.methodName == "ping"
    check parsed.request.params.values["customParam"].getBool
    check parsed.request.params.meta.hasClientInfo
    check parsed.request.params.meta.clientInfo.name == "test-client"
    check parsed.request.params.meta.clientCapabilities.fields["tools"][
      "listChanged"].getBool
    check parsed.request.params.meta.hasTraceContext
    check parsed.request.params.meta.traceContext.traceparent == "00-abc-def-01"
    check parsed.request.params.meta.traceContext.extensionFields["vendor"][
      "sampled"].getBool
    check parsed.request.params.meta.hasLogLevel
    check parsed.request.params.meta.logLevel == mcpLogDebug
    let roundTrip = toJson(parsed)
    check roundTrip["com.example/requestExtension"].getStr == "preserved"
    check roundTrip["params"]["customParam"].getBool
    check roundTrip["params"]["_meta"]["io.modelcontextprotocol/clientInfo"][
      "com.example/clientField"].getStr == "preserved"
    check roundTrip["params"]["_meta"]["com.example/extension"][
      "enabled"].getBool

  test "models result types and error responses":
    let result = newMcpResult(mcpInputRequired, %*{
      "requestState": "opaque-state",
      "com.example/resultExtension": 1
    })
    let response = successResponse(McpId(kind: mcpIntegerId, integerValue: 8),
      result)
    let parsedResponse = parseMcpMessage(toJson(response))
    check parsedResponse.kind == mcpResponseMessage
    check parsedResponse.response.result.resultType == mcpInputRequired
    check parsedResponse.response.result.fields["requestState"].getStr ==
      "opaque-state"
    let error = parseMcpMessage(%*{
      "jsonrpc": "2.0",
      "id": nil,
      "error": {
        "code": -32001,
        "message": "failed",
        "data": {"reason": "test"},
        "com.example/errorExtension": true
      }
    })
    check error.kind == mcpErrorMessage
    check error.errorResponse.id.kind == mcpNullId
    check error.errorResponse.error.code == -32001
    check error.errorResponse.error.data["reason"].getStr == "test"
    check error.errorResponse.error.extraFields[
      "com.example/errorExtension"].getBool

  test "does not respond to valid or failing notifications":
    var notification = modernRequest(8, "ping")
    notification.delete("id")
    check server.handleJson(notification).isNil
    notification = modernRequest(9, "tools/call", %*{
      "name": "missing",
      "arguments": {}
    })
    notification.delete("id")
    check server.handleJson(notification).isNil

  test "rejects invalid ids and methods as invalid requests":
    var request = modernRequest(10, "ping")
    request["id"] = newJNull()
    check server.handleJson(request)["error"]["code"].getInt ==
      mcpInvalidRequestCode
    request = modernRequest(11, "")
    check server.handleJson(request)["error"]["code"].getInt ==
      mcpInvalidRequestCode
    request = modernRequest(12, "rpc.reserved")
    check server.handleJson(request)["error"]["code"].getInt ==
      mcpInvalidRequestCode

  test "enforces parser size and nesting limits":
    expect McpError:
      discard parseMcpMessage($modernRequest(13, "ping"),
        maxMessageBytes = 16)
    expect McpError:
      discard parseMcpMessage($modernRequest(14, "ping"),
        maxNestingDepth = 2)

  test "validates tool names and schemas at registration":
    let handler: McpSyncToolHandler = proc (args: JsonNode): McpToolResult =
      textResult("ok")
    expect McpError:
      discard newMcpTool("bad name", "invalid", %*{"type": "object"}, handler)
    expect McpError:
      discard newMcpTool("valid-name", "invalid", %*{"type": "unknown"},
        handler)
    expect McpError:
      discard newMcpTool("valid-name", "invalid", %*{"type": "object"},
        handler, %*{"required": [1]})

  test "validates arguments before invoking a handler":
    var invoked = false
    let validationServer = newMcpServer("validation", "1.0.0")
    validationServer.addTool newMcpTool("typed", "Typed input", %*{
      "type": "object",
      "properties": {"count": {"type": "integer"}},
      "required": ["count"],
      "additionalProperties": false
    }, proc (args: JsonNode): McpToolResult =
      invoked = true
      textResult("ok"))
    let response = validationServer.handleJson(modernRequest(15, "tools/call",
      %*{"name": "typed", "arguments": {"count": "wrong"}}))
    check response["error"]["code"].getInt == mcpInvalidParamsCode
    check not invoked

  test "validates structured output and keeps its text representation":
    let outputServer = newMcpServer("output", "1.0.0")
    outputServer.addTool newMcpTool("typed-output", "Typed output", %*{
      "type": "object"
    }, proc (args: JsonNode): McpToolResult =
      structuredResult(%*{"value": "not an integer"}), %*{
        "type": "object",
        "properties": {"value": {"type": "integer"}},
        "required": ["value"]
      })
    var response = outputServer.handleJson(modernRequest(16, "tools/call",
      %*{"name": "typed-output", "arguments": {}}))
    check response["error"]["code"].getInt == mcpInternalErrorCode

    let textServer = newMcpServer("text", "1.0.0")
    textServer.addTool newMcpTool("structured", "Structured output", %*{
      "type": "object"
    }, proc (args: JsonNode): McpToolResult =
      McpToolResult(structuredContent: %*{"value": 1}))
    response = textServer.handleJson(modernRequest(17, "tools/call",
      %*{"name": "structured", "arguments": {}}))
    check response["result"]["content"].len == 1
    check response["result"]["content"][0]["type"].getStr == "text"
    check response["result"]["structuredContent"]["value"].getInt == 1

  test "builds all supported content blocks with annotations":
    let annotations = %*{"audience": ["user"]}
    check textContent("hello", annotations)["annotations"]["audience"][0].getStr ==
      "user"
    check imageContent("base64", "image/png")["type"].getStr == "image"
    check audioContent("base64", "audio/wav")["mimeType"].getStr == "audio/wav"
    let link = resourceLinkContent("file:///tmp/report.txt", "report",
      "text/plain", annotations = annotations)
    check link["type"].getStr == "resource_link"
    check link["annotations"].kind == JObject
    let embedded = embeddedResourceContent(%*{
      "uri": "file:///tmp/report.txt",
      "text": "report"
    }, annotations)
    check embedded["type"].getStr == "resource"
    check embedded["resource"]["text"].getStr == "report"

  test "publishes optional tool metadata":
    let metadataServer = newMcpServer("metadata", "1.0.0")
    metadataServer.addTool newMcpTool("metadata-tool", "Metadata", %*{
      "type": "object"
    }, proc (args: JsonNode): McpToolResult = textResult("ok"),
      title = "Metadata tool",
      icons = %*[{"src": "https://example.com/icon.svg"}],
      annotations = %*{"readOnlyHint": true})
    let response = metadataServer.handleJson(modernRequest(18, "tools/list"))
    let tool = response["result"]["tools"][0]
    check tool["title"].getStr == "Metadata tool"
    check tool["icons"][0]["src"].getStr == "https://example.com/icon.svg"
    check tool["annotations"]["readOnlyHint"].getBool

  test "paginates tools with opaque cursors and advertises mutations":
    let pagedServer = newMcpServer("paged", "1.0.0", listPageSize = 2)
    for name in ["charlie", "alpha", "bravo"]:
      pagedServer.addTool newMcpTool(name, "Tool " & name, %*{
        "type": "object"
      }, proc (args: JsonNode): McpToolResult = textResult(name))
    var response = pagedServer.handleJson(modernRequest(19, "tools/list"))
    check response["result"]["tools"].len == 2
    check response["result"]["tools"][0]["name"].getStr == "alpha"
    check response["result"]["tools"][1]["name"].getStr == "bravo"
    let cursor = response["result"]["nextCursor"].getStr
    check cursor.len > 0
    response = pagedServer.handleJson(modernRequest(20, "tools/list", %*{
      "cursor": cursor
    }))
    check response["result"]["tools"].len == 1
    check response["result"]["tools"][0]["name"].getStr == "charlie"
    pagedServer.markToolsChanged()
    response = pagedServer.handleJson(modernRequest(21, "server/discover"))
    check response["result"]["capabilities"]["tools"]["listChanged"].getBool
    response = pagedServer.handleJson(modernRequest(22, "tools/list", %*{
      "cursor": "not-a-valid-cursor"
    }))
    check response["error"]["code"].getInt == mcpInvalidParamsCode

suite "nimwire Streamable HTTP":
  proc httpHeaders(methodName: string, name = ""): seq[McpHttpHeader] =
    result = @[
      header("Content-Type", "application/json"),
      header("Accept", "application/json, text/event-stream"),
      header("MCP-Protocol-Version", mcpProtocolVersion),
      header("Mcp-Method", methodName)]
    if name.len > 0:
      result.add header("Mcp-Name", name)

  proc httpRequest(server: McpServer, body: JsonNode,
                   headers: seq[McpHttpHeader],
                   config = newMcpHttpConfig()): McpHttpResponse =
    waitFor server.handleHttpRequest(newMcpHttpRequest("POST", "/mcp",
      $body, headers), config)

  test "handles JSON requests and notifications statelessly":
    let server = newMcpServer("http", "1.0.0")
    let body = modernRequest(1, "ping")
    let response = httpRequest(server, body, httpHeaders("ping"))
    check response.status == 200
    check response.body.parseJson["result"]["resultType"].getStr == "complete"

    var notification = modernRequest(2, "ping")
    notification.delete("id")
    let accepted = httpRequest(server, notification, httpHeaders("ping"))
    check accepted.status == 202
    check accepted.body.len == 0

  test "rejects legacy methods and header mismatches":
    let server = newMcpServer("http", "1.0.0")
    let config = newMcpHttpConfig()
    let getResponse = waitFor server.handleHttpRequest(
      newMcpHttpRequest("GET", "/mcp"), config)
    check getResponse.status == 405

    var headers = httpHeaders("tools/list")
    headers[3].value = "ping"
    let mismatch = httpRequest(server, modernRequest(3, "tools/list"), headers)
    check mismatch.status == 400
    check mismatch.body.parseJson["error"]["code"].getInt ==
      mcpHeaderMismatchCode

  test "emits one request-scoped SSE response when selected":
    let server = newMcpServer("http", "1.0.0")
    let response = httpRequest(server, modernRequest(4, "ping"),
      httpHeaders("ping"), newMcpHttpConfig(preferSse = true))
    check response.status == 200
    check response.headers.anyIt(it.name == "Content-Type" and
      it.value.startsWith("text/event-stream"))
    check response.body.startsWith("event: message\r\ndata: {")
    check response.body.endsWith("\r\n\r\n")

  test "validates standard and schema-driven parameter headers":
    let server = newMcpServer("http", "1.0.0")
    server.addTool newMcpTool("echo-header", "Echo a header", %*{
      "type": "object",
      "properties": {
        "region": {"type": "string", "x-mcp-header": "Region"}
      },
      "required": ["region"]
    }, proc (args: JsonNode): McpToolResult = textResult(args["region"].getStr))
    let body = modernRequest(5, "tools/call", %*{
      "name": "echo-header", "arguments": {"region": "東京"}
    })
    var headers = httpHeaders("tools/call", "echo-header")
    headers.add header("Mcp-Param-Region", encodeMcpHeaderValue("東京"))
    check httpRequest(server, body, headers).status == 200

    headers[^1].value = "wrong"
    let mismatch = httpRequest(server, body, headers)
    check mismatch.status == 400
    check mismatch.body.parseJson["error"]["code"].getInt ==
      mcpHeaderMismatchCode

    headers[^1].value = encodeMcpHeaderValue("東京")
    headers.delete(5)
    let missing = httpRequest(server, body, headers)
    check missing.status == 400

    expect McpError:
      discard newMcpTool("bad-header", "Invalid header", %*{
        "type": "object", "properties": {
          "items": {"type": "array", "items": {
            "type": "string", "x-mcp-header": "Nested"
          }}
        }
      }, proc (args: JsonNode): McpToolResult = textResult("ok"))

  test "enforces origin, host, and body controls":
    let server = newMcpServer("http", "1.0.0")
    let config = newMcpHttpConfig(allowedHosts = @["localhost"],
      allowedOrigins = @["https://client.example"], maxBodyBytes = 32)
    var headers = httpHeaders("ping")
    headers.add header("Host", "evil.example")
    let badHost = httpRequest(server, modernRequest(6, "ping"), headers, config)
    check badHost.status == 403

    headers[4].value = "localhost:8080"
    headers.add header("Origin", "https://evil.example")
    let badOrigin = httpRequest(server, modernRequest(7, "ping"), headers, config)
    check badOrigin.status == 403

    headers = httpHeaders("ping")
    headers.add header("Host", "localhost")
    let tooLarge = httpRequest(server, modernRequest(8, "ping"), headers, config)
    check tooLarge.status == 413
