import std/[asyncdispatch, json, options, os, sequtils, strutils, tables, times,
  unittest]
import ../src/nimwire

type
  Weather* = object
    temperature*: int
    condition*: string

  WeatherMode = enum
    wmCurrent
    wmForecast

  WeatherRequest = object
    city*: string
    mode*: WeatherMode
    units*: Option[string]
    tags*: seq[string]
    labels*: Table[string, int]

proc namedWeather(city: string): Weather =
  Weather(temperature: 16, condition: city & ": cloudy")

suite "nimwire MCP server":
  let server = mcpServer("test-server", "1.0.0"):
    server.addTool mcpTool("echo", "Echo text", %*{
      "type": "object",
      "properties": {"text": {"type": "string"}},
      "required": ["text"]
    }, proc (args: JsonNode, ignoredContext: McpContext): McpToolResult =
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

  test "derives typed tool schemas and round trips structured values":
    let server = newMcpServer("typed", "1.0.0")
    let derivedSchema = mcpJsonSchema(WeatherRequest)
    validateJsonSchema(derivedSchema)
    server.tool "weather", "Current weather",
      proc (request: WeatherRequest): Weather =
        Weather(temperature: request.labels["offset"] + 16,
          condition: request.city & ":" & $request.mode & ":" &
            (if request.units.isSome: request.units.get else: "default"))
    server.tool "named-weather", "Named typed handler", namedWeather
    server.tool "typed-result", "Typed result handler",
      proc (city: string): McpResult[Weather] =
        mcpResult(Weather(temperature: 20, condition: city & ": clear"))
    server.tool "typed-error", "Typed error handler",
      proc (city: string): McpResult[Weather] =
        mcpResultError[Weather]("unavailable", "weather unavailable",
          %*{"city": city})
    server.tool "async-typed-result", "Async typed result handler",
      proc (city: string): Future[McpResult[Weather]] {.async.} =
        await sleepAsync(0)
        mcpResult(Weather(temperature: 21, condition: city & ": windy"))

    let listed = server.handleJson(modernRequest(100, "tools/list"))
    var weather: JsonNode
    for item in listed["result"]["tools"].items:
      if item["name"].getStr == "weather": weather = item
    check not weather.isNil
    check weather["name"].getStr == "weather"
    check weather["inputSchema"]["type"].getStr == "object"
    check weather["inputSchema"]["properties"]["request"]["type"].getStr ==
      "object"
    check weather["inputSchema"]["properties"]["request"]["properties"][
      "mode"]["type"].getStr == "string"
    check weather["inputSchema"]["properties"]["request"]["properties"][
      "units"]["anyOf"][1]["type"].getStr == "null"
    check weather["outputSchema"]["properties"]["temperature"][
      "type"].getStr == "integer"

    let response = server.handleJson(modernRequest(101, "tools/call", %*{
      "name": "weather", "arguments": {"request": {
        "city": "Paris", "mode": "wmCurrent", "tags": ["today"],
        "labels": {"offset": 2}
      }}
    }))
    check response["result"]["structuredContent"]["temperature"].getInt == 18
    check response["result"]["structuredContent"]["condition"].getStr ==
      "Paris:wmCurrent:default"

    let named = server.handleJson(modernRequest(102, "tools/call", %*{
      "name": "named-weather", "arguments": {"city": "London"}
    }))
    check named["result"]["structuredContent"]["condition"].getStr ==
      "London: cloudy"
    let typed = server.handleJson(modernRequest(108, "tools/call", %*{
      "name": "typed-result", "arguments": {"city": "Rome"}
    }))
    check typed["result"]["structuredContent"]["temperature"].getInt == 20
    let typedError = server.handleJson(modernRequest(109, "tools/call", %*{
      "name": "typed-error", "arguments": {"city": "Rome"}
    }))
    check typedError["result"]["isError"].getBool
    check typedError["result"]["content"][0]["text"].getStr ==
      "weather unavailable"
    let asyncTyped = server.handleJson(modernRequest(116, "tools/call", %*{
      "name": "async-typed-result", "arguments": {"city": "Rome"}
    }))
    check asyncTyped["result"]["structuredContent"]["temperature"].getInt == 21

    let declarative = mcpServer("typed-declarative", "1.0.0"):
      server.tool "city", "Echo city", proc (city: string): string = city
    let declarativeResponse = declarative.handleJson(modernRequest(107,
      "tools/call", %*{"name": "city", "arguments": {"city": "Rome"}}))
    check declarativeResponse["result"]["structuredContent"].getStr == "Rome"

  test "supports direct typed arguments, explicit schemas, and async context":
    let server = newMcpServer("typed-overrides", "1.0.0")
    server.tool "echo-typed", "Echo typed text",
      proc (city: string): string = city,
      inputSchema = %*{"type": "object", "properties": {
        "city": {"type": "string", "minLength": 1}},
        "required": ["city"]},
      outputSchema = %*{"type": "string"}
    server.tool "async-typed", "Async typed tool",
      proc (context: McpContext, city: string): Future[string] {.async.} =
        await sleepAsync(0)
        city & ":" & context.methodName
    server.tool "async-result", "Async MCP result tool",
      proc (city: string): Future[McpToolResult] {.async.} =
        await sleepAsync(0)
        textResult(city)

    let echo = server.handleJson(modernRequest(103, "tools/call", %*{
      "name": "echo-typed", "arguments": {"city": "Paris"}
    }))
    let definitions = server.handleJson(modernRequest(105, "tools/list"))
    let echoDefinition = definitions["result"]["tools"][2]
    check echoDefinition["inputSchema"]["properties"]["city"][
      "minLength"].getInt == 1
    check echoDefinition["outputSchema"]["type"].getStr == "string"
    check echo["result"]["structuredContent"].getStr == "Paris"

    let asyncResponse = server.handleJson(modernRequest(104, "tools/call", %*{
      "name": "async-typed", "arguments": {"city": "Paris"}
    }))
    check asyncResponse["result"]["structuredContent"].getStr ==
      "Paris:tools/call"
    let rawAsyncResponse = server.handleJson(modernRequest(106, "tools/call",
      %*{"name": "async-result", "arguments": {"city": "Paris"}}))
    check rawAsyncResponse["result"]["content"][0]["text"].getStr == "Paris"

  test "declares typed results and context helpers without raw JSON":
    let server = newMcpServer("typed-helpers", "1.0.0")
    server.tool "contextual", "Contextual typed tool",
      proc (cancel: McpCancellation, progress: McpProgressReporter,
            city: string): string =
        discard cancel
        check progress.isNil
        city
    let response = server.handleJson(modernRequest(110, "tools/call", %*{
      "name": "contextual", "arguments": {"city": "Dublin"}
    }))
    check response["result"]["structuredContent"].getStr == "Dublin"

  test "links peers in process and mounts collision-safe remote features":
    let remote = newMcpServer("remote", "1.0.0", listPageSize = 1)
    remote.addTool mcpTool("echo", "Remote echo", %*{
      "type": "object", "properties": {"text": {"type": "string"}},
      "required": ["text"]
    }, proc (arguments: JsonNode, context: McpContext): McpToolResult =
      textResult("remote:" & arguments["text"].getStr))
    remote.addResource mcpResource("urn:remote:doc", "doc",
      resourceText("urn:remote:doc", "remote document", "text/plain"))
    let remoteTemplateHandler: McpSyncResourceTemplateReadHandler =
      proc (uri: string, arguments: JsonNode,
            context: McpContext): seq[McpResourceContent] = @[
        resourceText(uri, "remote:" & arguments["id"].getStr)]
    var remoteTemplate = newMcpResourceTemplate("urn:remote:{id}", "record",
      remoteTemplateHandler)
    let remoteResourceCompletion: McpSyncResourceCompletionHandler =
      proc (argument, prefix: string,
            context: McpContext): seq[string] = @[prefix & "-record"]
    remoteTemplate.addCompletion("id", remoteResourceCompletion)
    remote.addResourceTemplate remoteTemplate
    var remotePrompt = newMcpPrompt("greet",
      proc (arguments: McpPromptArguments,
            context: McpContext): McpPromptMessage =
        userText("Hello " & arguments["name"]),
      arguments = @[newMcpPromptArgument("name", required = true)])
    let remotePromptCompletion: McpSyncPromptCompletionHandler =
      proc (argument, prefix: string,
            context: McpContext): seq[string] = @[prefix & "-name"]
    remotePrompt.addCompletion("name", remotePromptCompletion)
    remote.addPrompt remotePrompt

    let peer = newMcpInProcessPeer(remote)
    check (peer.request("server/discover")).resultType == mcpComplete
    let local = newMcpServer("local", "1.0.0")
    discard local.mountMcpServer(peer.transport, "upstream")

    let tools = local.handleJson(modernRequest(117, "tools/list"))
    check tools["result"]["tools"][0]["name"].getStr == "upstream.echo"
    let call = local.handleJson(modernRequest(118, "tools/call", %*{
      "name": "upstream.echo", "arguments": {"text": "ok"}}))
    check call["result"]["content"][0]["text"].getStr == "remote:ok"

    let resources = local.handleJson(modernRequest(119, "resources/list"))
    let resourceUri = resources["result"]["resources"][0]["uri"].getStr
    check resources["result"]["resources"][0]["name"].getStr == "upstream.doc"
    let resource = local.handleJson(modernRequest(120, "resources/read", %*{
      "uri": resourceUri}))
    check resource["result"]["contents"][0]["text"].getStr ==
      "remote document"

    let templates = local.handleJson(modernRequest(121,
      "resources/templates/list"))
    let templateUri = templates["result"]["resourceTemplates"][0][
      "uriTemplate"].getStr
    check templateUri == "urn:nimwire:proxy:upstream:urn:remote:{id}"
    let templateResponse = local.handleJson(modernRequest(122, "resources/read", %*{
      "uri": "urn:nimwire:proxy:upstream:urn:remote:seven"}))
    check templateResponse["result"]["contents"][0]["text"].getStr ==
      "remote:seven"
    let completionContext = newMcpContext(
      parseMcpMessage(modernRequest(125, "ping")).request)
    let templateCompletions = waitFor local.completeResourceTemplate(
      templateUri, "id", "se", completionContext)
    check templateCompletions == @["se-record"]

    let prompts = local.handleJson(modernRequest(123, "prompts/list"))
    check prompts["result"]["prompts"][0]["name"].getStr == "upstream.greet"
    let prompt = local.handleJson(modernRequest(124, "prompts/get", %*{
      "name": "upstream.greet", "arguments": {"name": "Ada"}}))
    check prompt["result"]["messages"][0]["content"]["text"].getStr ==
      "Hello Ada"
    let promptCompletions = waitFor local.completePromptArgument(
      "upstream.greet", "name", "Ad", completionContext)
    check promptCompletions == @["Ad-name"]
    expect McpError:
      discard local.mountMcpServer(newMcpInProcessTransport(remote), "upstream")

  test "composes middleware, retries retryable failures, and groups tools":
    let server = newMcpServer("ergonomics", "1.0.0")
    var calls = 0
    var validations = 0
    var timings: seq[float]
    server.use mcpValidationMiddleware(
      proc (name: string, arguments: JsonNode, context: McpContext) =
        inc validations
        check name == "retry"
        check arguments.kind == JObject
        check not context.isNil)
    server.use mcpPolicyMiddleware(
      proc (name: string, arguments: JsonNode, context: McpContext): bool =
        name == "retry" and arguments.kind == JObject and not context.isNil)
    server.use mcpTimingMiddleware(
      proc (name: string, durationMs: float) = timings.add durationMs)
    server.use mcpRetryMiddleware(maxAttempts = 3)
    server.addTool mcpTool("retry", "Retryable tool", %*{"type": "object"},
      proc (arguments: JsonNode, context: McpContext): McpToolResult =
        inc calls
        if calls == 1: raise retryableMcpError("try again")
        textResult("ok"))
    let response = server.handleJson(modernRequest(111, "tools/call", %*{
      "name": "retry", "arguments": {}
    }))
    check response["result"]["content"][0]["text"].getStr == "ok"
    check calls == 2
    check validations == 1
    check timings.len == 1

    var grouped = newMcpToolGroup("math")
    grouped.addTool mcpTool("add", "Add", %*{"type": "object"},
      proc (arguments: JsonNode, context: McpContext): McpToolResult =
        textResult("sum"))
    server.addToolGroup(grouped)
    server.addTools("text", @[mcpTool("upper", "Upper",
      %*{"type": "object"}, proc (arguments: JsonNode,
        context: McpContext): McpToolResult = textResult("UP"))])
    let listed = server.handleJson(modernRequest(112, "tools/list"))
    check listed["result"]["tools"][0]["name"].getStr == "math.add"
    check listed["result"]["tools"][1]["name"].getStr == "retry"
    check listed["result"]["tools"][2]["name"].getStr == "text.upper"

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
            "tools": {"listChanged": true},
            "extensions": {"com.example/optional": {"enabled": true}}
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
    check parsed.request.params.meta.clientCapabilities.fields["extensions"][
      "com.example/optional"]["enabled"].getBool
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
    check roundTrip["params"]["_meta"][mcpMetaClientCapabilitiesKey][
      "extensions"]["com.example/optional"]["enabled"].getBool

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
    let handler: McpSyncToolHandler = proc (args: JsonNode,
                                            ignoredContext: McpContext): McpToolResult =
      textResult("ok")
    expect McpError:
      discard newMcpTool("bad name", "invalid", %*{"type": "object"}, handler)
    expect McpError:
      discard newMcpTool("valid-name", "invalid", %*{"type": "unknown"},
        handler)
    expect McpError:
      discard newMcpTool("valid-name", "invalid", %*{"type": "object"},
        handler, %*{"required": [1]})
    expect McpError:
      discard newMcpTool("valid-name", "invalid", %*{
        "type": "string", "pattern": "^ok$"
      }, handler)

  test "validates arguments before invoking a handler":
    var invoked = false
    let validationServer = newMcpServer("validation", "1.0.0")
    validationServer.addTool newMcpTool("typed", "Typed input", %*{
      "type": "object",
      "properties": {"count": {"type": "integer"}},
      "required": ["count"],
      "additionalProperties": false
      }, proc (args: JsonNode, ignoredContext: McpContext): McpToolResult =
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
    }, proc (args: JsonNode, ignoredContext: McpContext): McpToolResult =
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
    }, proc (args: JsonNode, ignoredContext: McpContext): McpToolResult =
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
    }, proc (args: JsonNode, ignoredContext: McpContext): McpToolResult = textResult("ok"),
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
      }, proc (args: JsonNode, ignoredContext: McpContext): McpToolResult =
        textResult(name))
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
    }, proc (args: JsonNode, ignoredContext: McpContext): McpToolResult =
      textResult(args["region"].getStr))
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
      }, proc (args: JsonNode, ignoredContext: McpContext): McpToolResult =
        textResult("ok"))

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

  test "cancels a timed-out handler":
    var cancelled = false
    let server = newMcpServer("timeout", "1.0.0")
    server.addTool newMcpTool("slow", "Slow tool", %*{"type": "object"},
      proc (args: JsonNode, context: McpContext): Future[McpToolResult] {.async.} =
        await sleepAsync(20)
        cancelled = context.isCancelled
        textResult("done"))
    let request = newMcpHttpRequest("POST", "/mcp",
      $modernRequest(9, "tools/call", %*{
        "name": "slow", "arguments": {}
      }), httpHeaders("tools/call", "slow"))
    let response = waitFor server.handleHttpRequest(request,
      newMcpHttpConfig(requestTimeoutMs = 1))
    check response.status == 408
    waitFor sleepAsync(30)
    check cancelled

  test "streams progress and the final response when requested":
    let server = newMcpServer("http-progress", "1.0.0")
    server.addTool newMcpTool("progress", "Progress", %*{"type": "object"},
      proc (args: JsonNode, context: McpContext): Future[McpToolResult] {.async.} =
        await context.reportProgress(0.5, 1.0, "halfway")
        textResult("done"))
    var body = modernRequest(10, "tools/call", %*{
      "name": "progress", "arguments": {}
    })
    body["params"]["_meta"]["progressToken"] = %"progress-10"
    var request = newMcpHttpRequest("POST", "/mcp", $body,
      httpHeaders("tools/call", "progress"))
    var streamed: seq[JsonNode]
    request.streamResponses = true
    request.streamWriter = proc (message: JsonNode): Future[void] {.async.} =
      streamed.add message
    request.notificationSender = request.streamWriter
    let response = waitFor server.handleHttpRequest(request)
    check response.streamed
    check streamed.len == 2
    check streamed[0]["method"].getStr == "notifications/progress"
    check streamed[1]["result"]["content"][0]["text"].getStr == "done"

  test "streams subscription messages through a framework writer":
    let server = newMcpServer("http-subscriptions", "1.0.0")
    let toolHandler: McpSyncToolHandler = proc (
        arguments: JsonNode,
        ignoredContext: McpContext): McpToolResult = textResult("ok")
    server.addTool newMcpTool("one", "One", %*{"type": "object"},
      toolHandler)
    server.markToolsChanged()
    var streamed: seq[JsonNode]
    var request = newMcpHttpRequest("POST", "/mcp",
      $modernRequest(10, "subscriptions/listen", %*{
        "notifications": {"toolsListChanged": true}
      }), httpHeaders("subscriptions/listen"))
    request.streamWriter = proc (message: JsonNode): Future[void] {.async.} =
      streamed.add message
    let response = waitFor server.handleHttpRequest(request)
    waitFor sleepAsync(0)
    check response.streamed
    check response.subscriptionId.integerValue == 10
    check streamed.len == 1
    check streamed[0]["method"].getStr ==
      "notifications/subscriptions/acknowledged"
    server.markToolsChanged()
    waitFor sleepAsync(0)
    check streamed.len == 2
    check streamed[1]["method"].getStr ==
      "notifications/tools/list_changed"
    discard server.closeSubscriptions()
    waitFor sleepAsync(0)
    check streamed.len == 3
    check streamed[2]["id"].getInt == 10

suite "nimwire request context":
  test "hides unexpected handler errors and logs them":
    var loggedMessage = ""
    let logger: McpLogger = proc (level: McpLogLevel, message: string) =
      loggedMessage = message
    let server = newMcpServer("errors", "1.0.0")
    server.addTool newMcpTool("fails", "Fails", %*{"type": "object"},
      proc (args: JsonNode, context: McpContext): Future[McpToolResult] {.async.} =
        raise newException(ValueError, "secret failure"))
    let message = parseMcpMessage(modernRequest(10, "tools/call", %*{
      "name": "fails", "arguments": {}
    }))
    let response = waitFor server.handleMessageAsync(message,
      newMcpContext(message.request, logger = logger))
    check response.get.errorResponse.error.message == "Internal server error"
    check loggedMessage == "request failed: tools/call"

  test "passes request metadata and scoped application state to handlers":
    let server = newMcpServer("context", "1.0.0")
    let stateStore = newMcpStateStore()
    let principal = newMcpPrincipal("user-1", %*{"role": "admin"})
    var logged = false
    var reported = false
    let logger: McpLogger = proc (level: McpLogLevel, message: string) =
      logged = level == mcpLogInfo and message == "called"
    let progress: McpProgressReporter = proc (value, total: float,
                                               message: string): Future[void] {.async.} =
      reported = value == 0.5 and total == 1.0 and message == "halfway"
    server.addTool newMcpTool("context-tool", "Reads context", %*{
      "type": "object"
    }, proc (args: JsonNode, context: McpContext): Future[McpToolResult] {.async.} =
      check context.methodName == "tools/call"
      check context.requestId.integerValue == 1
      check context.metadata.protocolVersion == mcpProtocolVersion
      check context.transport.kind == mcpTransportHttp
      check context.principal.subject == "user-1"
      check context.extensionState["requestTag"].getStr == "test"
      context.log(mcpLogInfo, "called")
      await context.reportProgress(0.5, 1.0, "halfway")
      let handle = context.mintStateHandle(%*{"step": 1})
      let claim = context.verifyStateHandle(handle)
      check claim.isSome
      check claim.get.value["step"].getInt == 1
      textResult("ok"))

    let body = modernRequest(1, "tools/call", %*{
      "name": "context-tool", "arguments": {}
    })
    var request = newMcpHttpRequest("POST", "/mcp", $body, @[
      header("Content-Type", "application/json"),
      header("Accept", "application/json, text/event-stream"),
      header("MCP-Protocol-Version", mcpProtocolVersion),
      header("Mcp-Method", "tools/call"),
      header("Mcp-Name", "context-tool")])
    request.principal = principal
    request.extensionState = %*{"requestTag": "test"}
    request.stateStore = stateStore
    request.logger = logger
    request.progress = progress
    let response = waitFor server.handleHttpRequest(request)
    check response.status == 200
    check logged
    check reported

  test "exposes cancellation and binds state handles to their subject":
    let server = newMcpServer("context", "1.0.0")
    let message = parseMcpMessage(modernRequest(2, "ping"))
    let cancellation = newMcpCancellation()
    cancellation.cancel()
    let context = newMcpContext(message.request, cancellation = cancellation)
    let response = waitFor server.handleMessageAsync(message, context)
    check response.isSome
    check response.get.errorResponse.error.code == mcpRequestCancelledCode

    let store = newMcpStateStore()
    let handle = store.mintStateHandle("user-1", %*{"ok": true})
    check handle.startsWith("nimwire.")
    check store.verifyStateHandle(handle, "wrong-user").isNone
    check store.verifyStateHandle(handle, "user-1").get.value["ok"].getBool
    check store.revokeStateHandle(handle)
    check store.verifyStateHandle(handle, "user-1").isNone

suite "nimwire resources":
  test "registers, lists, and reads text and binary resources":
    let server = newMcpServer("resources", "1.0.0", listPageSize = 1)
    server.addResource newMcpResource("file:///README.md", "README",
      resourceText("file:///README.md", "hello", "text/markdown"),
      title = "Project README", description = "Project documentation",
      annotations = %*{"audience": ["user"]})
    server.addResource newMcpResource("file:///image.png", "image",
      resourceBlob("file:///image.png", "AQI=", "image/png"))

    var response = server.handleJson(modernRequest(30, "server/discover"))
    check response["result"]["capabilities"]["resources"].kind == JObject
    response = server.handleJson(modernRequest(31, "resources/list"))
    check response["result"]["resources"].len == 1
    check response["result"]["resources"][0]["uri"].getStr ==
      "file:///README.md"
    check response["result"]["resources"][0]["title"].getStr ==
      "Project README"
    let cursor = response["result"]["nextCursor"].getStr
    response = server.handleJson(modernRequest(32, "resources/list", %*{
      "cursor": cursor
    }))
    check response["result"]["resources"][0]["uri"].getStr ==
      "file:///image.png"

    response = server.handleJson(modernRequest(33, "resources/read", %*{
      "uri": "file:///README.md"
    }))
    check response["result"]["contents"][0]["text"].getStr == "hello"
    check response["result"]["contents"][0]["mimeType"].getStr ==
      "text/markdown"
    response = server.handleJson(modernRequest(34, "resources/read", %*{
      "uri": "file:///image.png"
    }))
    check response["result"]["contents"][0]["blob"].getStr == "AQI="
    check "text" notin response["result"]["contents"][0]

  test "reads URI templates and exposes completion hooks":
    let server = newMcpServer("templates", "1.0.0")
    var resourceTemplate = newMcpResourceTemplate("demo:///{owner}/{name}",
      "Demo records", proc (uri: string, arguments: JsonNode,
                             ignoredContext: McpContext): seq[McpResourceContent] =
      @[resourceText(uri, arguments["owner"].getStr & ":" &
        arguments["name"].getStr, "text/plain")])
    resourceTemplate.addCompletion("owner",
      proc (argument, prefix: string,
            ignoredContext: McpContext): seq[string] = @[prefix & "-team"])
    server.addResourceTemplate(resourceTemplate)

    var response = server.handleJson(modernRequest(35,
      "resources/templates/list"))
    check response["result"]["resourceTemplates"][0]["uriTemplate"].getStr ==
      "demo:///{owner}/{name}"
    response = server.handleJson(modernRequest(36, "resources/read", %*{
      "uri": "demo:///acme/report"
    }))
    check response["result"]["contents"][0]["text"].getStr == "acme:report"
    let message = parseMcpMessage(modernRequest(37, "resources/read", %*{
      "uri": "demo:///acme/report"
    }))
    let completions = waitFor server.completeResourceTemplate(
      "demo:///{owner}/{name}", "owner", "ac",
      newMcpContext(message.request))
    check completions == @["ac-team"]

    response = server.handleJson(modernRequest(38, "resources/read", %*{
      "uri": "demo:///acme"
    }))
    check response["error"]["code"].getInt == mcpInvalidParamsCode

  test "confines file resources to their root":
    let root = getTempDir() / ("nimwire-resource-" & $getCurrentProcessId())
    let outside = root & "-outside.txt"
    createDir(root)
    writeFile(root / "inside.txt", "inside")
    writeFile(outside, "outside")
    defer:
      removeFile(root / "inside.txt")
      removeDir(root)
      removeFile(outside)
    check safeResourcePath(root, "inside.txt") ==
      expandFilename(root) / "inside.txt"
    expect McpError:
      discard safeResourcePath(root, "../" & outside.lastPathPart)
    let resource = newFileResource(root, "inside.txt",
      uriValue = "file:///inside.txt")
    let server = newMcpServer("files", "1.0.0")
    server.addResource(resource)
    let response = server.handleJson(modernRequest(40, "resources/read", %*{
      "uri": "file:///inside.txt"
    }))
    check response["result"]["contents"][0]["text"].getStr == "inside"

suite "nimwire declarative feature helpers":
  test "declares resources, templates, prompts, and completions":
    let server = newMcpServer("declarations", "1.0.0")
    server.addResource mcpResource("urn:demo:static", "static",
      resourceText("urn:demo:static", "hello", "text/plain"))
    let dynamicHandler: McpSyncResourceTemplateReadHandler =
      proc (uri: string, arguments: JsonNode,
            context: McpContext): seq[McpResourceContent] {.closure.} = @[
        resourceText(uri, arguments["id"].getStr, "text/plain")]
    server.addResourceTemplate mcpResourceTemplate("urn:demo:{id}", "dynamic",
      dynamicHandler)
    server.addPrompt mcpPrompt("greet",
      proc (arguments: McpPromptArguments,
            context: McpContext): seq[McpPromptMessage] {.closure.} =
        @[userText("Hello " & arguments["name"])],
      arguments = @[newMcpPromptArgument("name", required = true)])
    server.addPromptCompletion("greet", mcpCompletion("name",
      proc (argument, prefix: string,
            context: McpContext): seq[string] {.closure.} = @[prefix & "Ada"]))
    server.addResourceTemplateCompletion("urn:demo:{id}",
      mcpCompletion("id", proc (argument, prefix: string,
                                 context: McpContext): seq[string] {.closure.} =
        @[prefix & "one"]))

    let resource = server.handleJson(modernRequest(113, "resources/read", %*{
      "uri": "urn:demo:static"
    }))
    check resource["result"]["contents"][0]["text"].getStr == "hello"
    let prompt = server.handleJson(modernRequest(114, "prompts/get", %*{
      "name": "greet", "arguments": {"name": "Ada"}
    }))
    check prompt["result"]["messages"][0]["content"]["text"].getStr ==
      "Hello Ada"
    let completions = waitFor server.completePromptArgument("greet", "name", "A",
      newMcpContext(parseMcpMessage(modernRequest(115, "ping")).request))
    check completions[0] == "AAda"

suite "nimwire prompts":
  test "registers, lists, and gets prompts with typed arguments":
    let server = newMcpServer("prompts", "1.0.0", listPageSize = 1)
    let reviewHandler: McpSyncPromptHandler = proc (
        arguments: McpPromptArguments,
        ignoredContext: McpContext): seq[McpPromptMessage] =
      @[
        userText("Review " & getPromptArgument(arguments, "code")),
        assistantPrompt(imageContent("AQI=", "image/png"))]
    server.addPrompt newMcpPrompt("review", reviewHandler,
      description = "Review code",
      arguments = @[newMcpPromptArgument("code", "Code", required = true)],
      icons = %*[{"src": "https://example.com/prompt.svg"}])
    let plainHandler: McpSyncPromptSingleHandler = proc (
        arguments: McpPromptArguments,
        ignoredContext: McpContext): McpPromptMessage =
      assistantText("done")
    server.addPrompt newMcpPrompt("plain", plainHandler, title = "Plain")
    let completionHandler: McpSyncPromptCompletionHandler = proc (
        argument, prefix: string,
        ignoredContext: McpContext): seq[string] = @[prefix & "-review"]
    server.addPromptCompletion("review", "code", completionHandler)
    let completionContext = newMcpContext(
      parseMcpMessage(modernRequest(53, "prompts/get")).request)
    let completions = waitFor server.completePromptArgument("review", "code", "le",
      completionContext)
    check completions == @["le-review"]

    var response = server.handleJson(modernRequest(50, "server/discover"))
    check response["result"]["capabilities"]["prompts"][
      "listChanged"].getBool == false
    response = server.handleJson(modernRequest(51, "prompts/list"))
    check response["result"]["prompts"].len == 1
    check response["result"]["prompts"][0]["name"].getStr == "plain"
    let cursor = response["result"]["nextCursor"].getStr
    response = server.handleJson(modernRequest(52, "prompts/list", %*{
      "cursor": cursor
    }))
    check response["result"]["prompts"][0]["name"].getStr == "review"
    check response["result"]["prompts"][0]["description"].getStr ==
      "Review code"
    check response["result"]["prompts"][0]["arguments"][0]["required"].getBool
    check response["result"]["prompts"][0]["icons"][0]["src"].getStr ==
      "https://example.com/prompt.svg"

    response = server.handleJson(modernRequest(53, "prompts/get", %*{
      "name": "review", "arguments": {"code": "let x = 1"}
    }))
    check response["result"]["description"].getStr == "Review code"
    check response["result"]["messages"][0]["role"].getStr == "user"
    check response["result"]["messages"][0]["content"]["text"].getStr ==
      "Review let x = 1"
    check response["result"]["messages"][1]["role"].getStr == "assistant"
    check response["result"]["messages"][1]["content"]["type"].getStr ==
      "image"

  test "supports every prompt content kind":
    let server = newMcpServer("prompt-content", "1.0.0")
    let handler: McpSyncPromptHandler = proc (
        arguments: McpPromptArguments,
        ignoredContext: McpContext): seq[McpPromptMessage] =
      @[
        userText("hello"),
        userPrompt(audioContent("AQI=", "audio/wav")),
        userPrompt(resourceLinkContent("memo://today", "Today's memo")),
        assistantPrompt(embeddedResourceContent(%*{
          "uri": "memo://today", "text": "Ship it"
        }))]
    server.addPrompt newMcpPrompt("all-content", handler)
    let response = server.handleJson(modernRequest(54, "prompts/get", %*{
      "name": "all-content"
    }))
    check response["result"]["messages"].len == 4
    check response["result"]["messages"][1]["content"]["type"].getStr ==
      "audio"
    check response["result"]["messages"][2]["content"]["type"].getStr ==
      "resource_link"
    check response["result"]["messages"][3]["content"]["type"].getStr ==
      "resource"

  test "rejects invalid prompt arguments and content":
    let server = newMcpServer("prompt-validation", "1.0.0")
    let handler: McpSyncPromptHandler = proc (
        arguments: McpPromptArguments,
        ignoredContext: McpContext): seq[McpPromptMessage] = @[userText("ok")]
    server.addPrompt newMcpPrompt("required", handler,
      arguments = @[newMcpPromptArgument("value", required = true)])
    var response = server.handleJson(modernRequest(55, "prompts/get", %*{
      "name": "required"
    }))
    check response["error"]["code"].getInt == mcpInvalidParamsCode
    response = server.handleJson(modernRequest(56, "prompts/get", %*{
      "name": "required", "arguments": {"unknown": "x"}
    }))
    check response["error"]["code"].getInt == mcpInvalidParamsCode
    response = server.handleJson(modernRequest(57, "prompts/get", %*{
      "name": "required", "arguments": {"value": 1}
    }))
    check response["error"]["code"].getInt == mcpInvalidParamsCode
    response = server.handleJson(modernRequest(58, "prompts/get", %*{
      "name": "missing"
    }))
    check response["error"]["code"].getInt == mcpInvalidParamsCode
    expect McpError:
      discard newMcpPromptMessage(mcpPromptUser, %*{"type": "video"})

  test "marks prompt listings as changed":
    let server = newMcpServer("prompt-changes", "1.0.0")
    let handler: McpSyncPromptSingleHandler = proc (
        arguments: McpPromptArguments,
        ignoredContext: McpContext): McpPromptMessage = userText("ok")
    server.addPrompt newMcpPrompt("one", handler)
    expect McpError:
      server.addPrompt newMcpPrompt("one", handler)
    server.markPromptsChanged()
    let response = server.handleJson(modernRequest(59, "server/discover"))
    check response["result"]["capabilities"]["prompts"][
      "listChanged"].getBool

suite "nimwire completion":
  test "completes prompt and resource-template arguments":
    let server = newMcpServer("completion", "1.0.0")
    let promptHandler: McpSyncPromptSingleHandler = proc (
        arguments: McpPromptArguments,
        ignoredContext: McpContext): McpPromptMessage = userText("ok")
    server.addPrompt newMcpPrompt("review", promptHandler,
      arguments = @[
        newMcpPromptArgument("language"),
        newMcpPromptArgument("code")])
    let promptCompletion: McpSyncPromptCompletionHandler = proc (
        argument, prefix: string,
        context: McpContext): seq[string] =
      @[prefix & context.completionArguments["code"].getStr]
    server.addPromptCompletion("review", "language", promptCompletion)

    var resourceTemplate = newMcpResourceTemplate("demo:///{owner}/{name}",
      "Demo", proc (uri: string, arguments: JsonNode,
                     ignoredContext: McpContext): seq[McpResourceContent] = @[])
    let resourceCompletion: McpSyncResourceCompletionHandler = proc (
        argument, prefix: string,
        ignoredContext: McpContext): seq[string] = @[prefix & "-team"]
    resourceTemplate.addCompletion("owner", resourceCompletion)
    server.addResourceTemplate(resourceTemplate)

    var response = server.handleJson(modernRequest(60, "server/discover"))
    check response["result"]["capabilities"]["completions"].kind == JObject
    response = server.handleJson(modernRequest(61, "completion/complete", %*{
      "ref": {"type": "ref/prompt", "name": "review"},
      "argument": {"name": "language", "value": "py"},
      "context": {"arguments": {"code": "discard"}}
    }))
    check response["result"]["completion"]["values"].len == 1
    check response["result"]["completion"]["values"][0].getStr == "pydiscard"
    check response["result"]["completion"]["total"].getInt == 1
    check not response["result"]["completion"]["hasMore"].getBool

    response = server.handleJson(modernRequest(62, "completion/complete", %*{
      "ref": {"type": "ref/resource",
               "uri": "demo:///{owner}/{name}"},
      "argument": {"name": "owner", "value": "ac"},
      "context": {"arguments": {"name": "report"}}
    }))
    check response["result"]["completion"]["values"][0].getStr == "ac-team"

  test "rejects invalid completion references and arguments":
    let server = newMcpServer("completion-validation", "1.0.0")
    let handler: McpSyncPromptSingleHandler = proc (
        arguments: McpPromptArguments,
        ignoredContext: McpContext): McpPromptMessage = userText("ok")
    server.addPrompt newMcpPrompt("review", handler,
      arguments = @[newMcpPromptArgument("language")])
    let base = %*{
      "ref": {"type": "ref/prompt", "name": "review"},
      "argument": {"name": "language", "value": "p"}
    }
    var response = server.handleJson(modernRequest(63,
      "completion/complete", base))
    check response["result"]["completion"]["values"].len == 0
    var request = modernRequest(64, "completion/complete", %*{
      "argument": {"name": "language", "value": "p"}
    })
    response = server.handleJson(request)
    check response["error"]["code"].getInt == mcpInvalidParamsCode
    request = modernRequest(65, "completion/complete", %*{
      "ref": {"type": "ref/unknown", "name": "review"},
      "argument": {"name": "language", "value": "p"}
    })
    response = server.handleJson(request)
    check response["error"]["code"].getInt == mcpInvalidParamsCode
    request = modernRequest(66, "completion/complete", %*{
      "ref": {"type": "ref/prompt", "name": "missing"},
      "argument": {"name": "language", "value": "p"}
    })
    response = server.handleJson(request)
    check response["error"]["code"].getInt == mcpInvalidParamsCode
    request = modernRequest(67, "completion/complete", %*{
      "ref": {"type": "ref/prompt", "name": "review"},
      "argument": {"name": "missing", "value": "p"}
    })
    response = server.handleJson(request)
    check response["error"]["code"].getInt == mcpInvalidParamsCode
    request = modernRequest(68, "completion/complete", %*{
      "ref": {"type": "ref/prompt", "name": "review"},
      "argument": {"name": "language", "value": "p"},
      "context": {"arguments": {"language": 1}}
    })
    response = server.handleJson(request)
    check response["error"]["code"].getInt == mcpInvalidParamsCode

  test "bounds large completion result sets":
    let server = newMcpServer("completion-limit", "1.0.0")
    let handler: McpSyncPromptSingleHandler = proc (
        arguments: McpPromptArguments,
        ignoredContext: McpContext): McpPromptMessage = userText("ok")
    server.addPrompt newMcpPrompt("large", handler,
      arguments = @[newMcpPromptArgument("value")])
    var suggestions = newSeq[string](mcpDefaultCompletionLimit + 7)
    for index in 0 ..< suggestions.len:
      suggestions[index] = "value-" & $index
    let completion: McpSyncPromptCompletionHandler = proc (
        argument, prefix: string,
        ignoredContext: McpContext): seq[string] = suggestions
    server.addPromptCompletion("large", "value", completion)
    let response = server.handleJson(modernRequest(69, "completion/complete", %*{
      "ref": {"type": "ref/prompt", "name": "large"},
      "argument": {"name": "value", "value": "v"}
    }))
    check response["result"]["completion"]["values"].len ==
      mcpDefaultCompletionLimit
    check response["result"]["completion"]["values"][99].getStr == "value-99"
    check response["result"]["completion"]["total"].getInt ==
      mcpDefaultCompletionLimit + 7
    check response["result"]["completion"]["hasMore"].getBool

suite "nimwire subscriptions":
  test "acknowledges filters, routes changes, and closes gracefully":
    let server = newMcpServer("subscriptions", "1.0.0")
    let toolHandler: McpSyncToolHandler = proc (
        arguments: JsonNode,
        ignoredContext: McpContext): McpToolResult = textResult("ok")
    server.addTool newMcpTool("one", "One", %*{"type": "object"},
      toolHandler)
    let promptHandler: McpSyncPromptSingleHandler = proc (
        arguments: McpPromptArguments,
        ignoredContext: McpContext): McpPromptMessage = userText("ok")
    server.addPrompt newMcpPrompt("one", promptHandler)
    server.addResource newMcpResource("memo://one", "One",
      resourceText("memo://one", "one"))
    server.markToolsChanged()
    server.markPromptsChanged()
    server.markResourcesChanged()

    var messages: seq[JsonNode]
    let handler: McpSubscriptionMessageHandler = proc (message: JsonNode) =
      messages.add message
    let request = modernRequest(70, "subscriptions/listen", %*{
      "notifications": {
        "toolsListChanged": true,
        "promptsListChanged": true,
        "resourcesListChanged": true,
        "resourceSubscriptions": ["memo://one"]
      }
    })
    let message = parseMcpMessage(request)
    let context = newMcpContext(message.request)
    let output = waitFor server.handleMessageAsync(message, context, handler)
    check output.isNone
    check messages.len == 1
    check messages[0]["method"].getStr ==
      "notifications/subscriptions/acknowledged"
    check messages[0]["params"]["notifications"]["toolsListChanged"].getBool
    check messages[0]["params"]["notifications"][
      "resourceSubscriptions"][0].getStr == "memo://one"

    server.markToolsChanged()
    server.markPromptsChanged()
    server.markResourcesChanged()
    server.markResourceUpdated("memo://one")
    check messages.len == 5
    check messages[1]["method"].getStr ==
      "notifications/tools/list_changed"
    check messages[2]["method"].getStr ==
      "notifications/prompts/list_changed"
    check messages[3]["method"].getStr ==
      "notifications/resources/list_changed"
    check messages[4]["method"].getStr ==
      "notifications/resources/updated"
    check messages[4]["params"]["uri"].getStr == "memo://one"
    check messages[4]["params"]["_meta"][
      "io.modelcontextprotocol/subscriptionId"].getInt == 70

    check server.subscriptionCount == 1
    check server.closeSubscriptions() == 1
    check server.subscriptionCount == 0
    check messages.len == 6
    check messages[5]["id"].getInt == 70
    check messages[5]["result"]["resultType"].getStr == "complete"
    check messages[5]["result"]["_meta"][
      "io.modelcontextprotocol/subscriptionId"].getInt == 70

  test "honors opt-in filters and cancellation":
    let server = newMcpServer("subscription-filter", "1.0.0")
    let toolHandler: McpSyncToolHandler = proc (
        arguments: JsonNode,
        ignoredContext: McpContext): McpToolResult = textResult("ok")
    server.addTool newMcpTool("one", "One", %*{"type": "object"},
      toolHandler)
    server.markToolsChanged()
    var messages: seq[JsonNode]
    let handler: McpSubscriptionMessageHandler = proc (message: JsonNode) =
      messages.add message
    let listen = parseMcpMessage(modernRequest(71, "subscriptions/listen", %*{
      "notifications": {"toolsListChanged": true}
    }))
    discard waitFor server.handleMessageAsync(listen,
      newMcpContext(listen.request), handler)
    check messages.len == 1
    server.markPromptsChanged()
    check messages.len == 1
    server.markToolsChanged()
    check messages.len == 2
    var cancel = modernRequest(72, "notifications/cancelled", %*{
      "requestId": 71
    })
    cancel.delete("id")
    let cancelMessage = parseMcpMessage(cancel)
    let cancelOutput = waitFor server.handleMessageAsync(cancelMessage,
      newMcpContext(cancelMessage.request))
    check cancelOutput.isNone
    check server.subscriptionCount == 0
    server.markToolsChanged()
    check messages.len == 2

  test "supports an explicit publisher backend":
    var published: seq[McpSubscriptionEventKind]
    let publisher: McpEventPublisher = proc (event: McpSubscriptionEvent) =
      published.add event.kind
    let bus = newMcpEventBus(publisher)
    let server = newMcpServer("publisher", "1.0.0", eventBus = bus)
    server.markToolsChanged()
    server.markPromptsChanged()
    check published == @[mcpToolsListChanged, mcpPromptsListChanged]

suite "nimwire multi round-trip requests":
  test "retries input_required tools with responses and opaque state":
    let server = newMcpServer("mrtr", "1.0.0")
    server.addTool newMcpTool("profile", "Build a profile", %*{
      "type": "object"
    }, proc (arguments: JsonNode,
            context: McpContext): McpToolResult =
      if context.inputResponses.len == 0:
        context.requireInput(newMcpInputRequiredResult(@[
          ("name", newMcpElicitationFormRequest("What is your name?", %*{
            "type": "object",
            "properties": {"name": {"type": "string", "minLength": 2}},
            "required": ["name"]
          }))
        ], "opaque-state-v1"))
      else:
        check context.inputResponse("name")["action"].getStr == "accept"
        check context.requestState == "opaque-state-v1"
        check context.inputResponse("name")["content"]["name"].getStr == "Ada"
      textResult("done"))

    let original = parseMcpMessage(modernRequest(100, "tools/call", %*{
      "name": "profile", "arguments": {}
    }))
    let firstResponse = parseMcpMessage(server.handleJson(
      modernRequest(100, "tools/call", %*{
        "name": "profile", "arguments": {}
      })))
    check firstResponse.response.result.resultType == mcpInputRequired
    check firstResponse.response.result.fields["requestState"].getStr ==
      "opaque-state-v1"

    let client = newMcpInputClient(firstRequestId = 101,
      elicitationHandler = proc (
          request: McpElicitationRequest): McpElicitationResult =
        acceptElicitation(%*{"name": "Ada"}))
    let retry = client.retryInputRequired(original, firstResponse)
    check retry.request.id.integerValue != original.request.id.integerValue
    check retry.request.params.values["requestState"].getStr ==
      firstResponse.response.result.fields["requestState"].getStr
    let finalResponse = server.handleJson(toJson(retry))
    check finalResponse["id"].getInt == retry.request.id.integerValue
    check finalResponse["result"]["resultType"].getStr == "complete"
    check finalResponse["result"]["content"][0]["text"].getStr == "done"

  test "handles elicitation, sampling, and roots input requests":
    let result = newMcpInputRequiredResult(@[
      ("ask", newMcpElicitationFormRequest("Name", %*{
        "type": "object", "properties": {"name": {"type": "string"}},
        "required": ["name"]
      })),
      ("sample", newMcpInputRequest("sampling/createMessage", %*{
        "messages": []
      })),
      ("roots", newMcpInputRequest("roots/list"))
    ], "opaque")
    let original = parseMcpMessage(modernRequest(110, "tools/call", %*{
      "name": "unused", "arguments": {}
    }))
    let response = successResponse(original.request.id, result)
    let client = newMcpInputClient(firstRequestId = 111,
      elicitationHandler = proc (
          request: McpElicitationRequest): McpElicitationResult =
        acceptElicitation(%*{"name": "Ada"}),
      samplingHandler = proc (request: McpInputRequest): JsonNode =
        %*{"role": "assistant", "content": {"type": "text", "text": "ok"}},
      rootsHandler = proc (request: McpInputRequest): JsonNode =
        %*{"roots": []})
    let retry = client.retryInputRequired(original,
      parseMcpMessage(toJson(response)), client.freshRequestId())
    check retry.request.params.values["inputResponses"]["ask"][
      "content"]["name"].getStr == "Ada"
    check retry.request.params.values["inputResponses"]["sample"][
      "role"].getStr == "assistant"
    check retry.request.params.values["inputResponses"]["roots"][
      "roots"].kind == JArray

  test "rejects invalid accepted form content and reused retry ids":
    let result = newMcpInputRequiredResult(@[
      ("ask", newMcpElicitationFormRequest("Name", %*{
        "type": "object", "properties": {"name": {"type": "string"}},
        "required": ["name"]
      }))
    ])
    let original = parseMcpMessage(modernRequest(120, "tools/call", %*{
      "name": "unused", "arguments": {}
    }))
    let response = parseMcpMessage(toJson(
      successResponse(original.request.id, result)))
    let badClient = newMcpInputClient(firstRequestId = 121,
      elicitationHandler = proc (
          request: McpElicitationRequest): McpElicitationResult =
        acceptElicitation(%*{"name": 7}))
    expect McpError:
      discard badClient.retryInputRequired(original, response,
        badClient.freshRequestId())

    let client = newMcpInputClient(firstRequestId = 122)
    expect McpError:
      discard client.retryInputRequired(original, response, original.request.id)

  test "binds verified request state to the request context":
    var sealed = false
    var verified = false
    let sealer: McpRequestStateSealer = proc (
        payload: JsonNode, context: McpContext): string =
      sealed = true
      "sealed:" & payload["step"].getStr
    let verifier: McpRequestStateVerifier = proc (
        state: string, context: McpContext): JsonNode =
      verified = state == "sealed:1" and context.principal.subject == "user"
      if verified: %*{"step": "1"} else: nil
    let server = newMcpServer("state", "1.0.0",
      requestStateSealer = sealer, requestStateVerifier = verifier)
    server.addTool newMcpTool("stateful", "Stateful", %*{"type": "object"},
      proc (arguments: JsonNode, context: McpContext): McpToolResult =
        if context.inputResponses.len == 0:
          context.requireInput(newMcpInputRequiredResult(nil,
            context.sealRequestState(%*{"step": "1"})))
        else:
          check context.requestStatePayload["step"].getStr == "1"
        textResult("ok"))
    let principal = newMcpPrincipal("user")
    let request = modernRequest(130, "tools/call", %*{
      "name": "stateful", "arguments": {}
    })
    let first = parseMcpMessage(request)
    let firstContext = newMcpContext(first.request, principal = principal)
    let firstOutput = waitFor server.handleMessageAsync(first, firstContext)
    check firstOutput.get.response.result.fields["requestState"].getStr ==
      "sealed:1"
    check sealed
    let retryRequest = modernRequest(131, "tools/call", %*{
      "name": "stateful", "arguments": {},
      "inputResponses": {"done": {"action": "accept"}},
      "requestState": "sealed:1"
    })
    let retryMessage = parseMcpMessage(retryRequest)
    let retryContext = newMcpContext(retryMessage.request,
      principal = principal)
    let retryOutput = waitFor server.handleMessageAsync(retryMessage,
      retryContext)
    check retryOutput.get.response.result.resultType == mcpComplete
    check verified

suite "nimwire cancellation, progress, and timeouts":
  test "emits progress notifications from a request token":
    var request = modernRequest(140, "ping")
    request["params"]["_meta"]["progressToken"] = %"progress-1"
    let message = parseMcpMessage(request)
    var notifications: seq[JsonNode]
    let sender: McpNotificationSender = proc (notification: JsonNode): Future[void] {.async.} =
      notifications.add notification
    let context = newMcpContext(message.request, notificationSender = sender)
    waitFor context.reportProgress(1.0, 2.0, "started")
    waitFor context.reportProgress(2.0, 2.0, "finished")
    check notifications.len == 2
    check notifications[0]["method"].getStr == "notifications/progress"
    check notifications[0]["params"]["progressToken"].getStr == "progress-1"
    check notifications[1]["params"]["progress"].getFloat == 2.0
    expect McpError:
      waitFor context.reportProgress(2.0, 2.0)

  test "cancels active requests and exposes the cancellation reason":
    let server = newMcpServer("cancel", "1.0.0")
    var observedReason = ""
    server.addTool newMcpTool("slow", "Slow", %*{"type": "object"},
      proc (args: JsonNode, context: McpContext): Future[McpToolResult] {.async.} =
        await sleepAsync(20)
        observedReason = context.cancellation.reason
        context.checkCancelled()
        textResult("done"))
    let message = parseMcpMessage(modernRequest(141, "tools/call", %*{
      "name": "slow", "arguments": {}
    }))
    let context = newMcpContext(message.request)
    let pending = server.handleMessageAsync(message, context)
    waitFor sleepAsync(1)
    check server.cancelRequest(message.request.id, "client left")
    check context.cancellation.waitCancelled().finished
    let output = waitFor pending
    check output.get.errorResponse.error.code == mcpRequestCancelledCode
    check observedReason == "client left"
    check not server.cancelRequest(message.request.id)

  test "enforces per-tool deadlines and cancels on shutdown":
    let server = newMcpServer("tool-timeout", "1.0.0")
    var timedOut = false
    server.addTool newMcpTool("slow", "Slow", %*{"type": "object"},
      proc (args: JsonNode, context: McpContext): Future[McpToolResult] {.async.} =
        await sleepAsync(20)
        timedOut = context.isCancelled
        context.checkCancelled()
        textResult("done"))
    server.setToolTimeout("slow", 1)
    let response = server.handleJson(modernRequest(142, "tools/call", %*{
      "name": "slow", "arguments": {}
    }))
    check response["error"]["code"].getInt == mcpInternalErrorCode
    waitFor sleepAsync(25)
    check timedOut

    var shutdownSeen = false
    server.addTool newMcpTool("shutdown-wait", "Wait", %*{"type": "object"},
      proc (args: JsonNode, context: McpContext): Future[McpToolResult] {.async.} =
        await sleepAsync(20)
        shutdownSeen = context.isCancelled
        context.checkCancelled()
        textResult("done"))
    let message = parseMcpMessage(modernRequest(143, "tools/call", %*{
      "name": "shutdown-wait", "arguments": {}
    }))
    let pending = server.handleMessageAsync(message, newMcpContext(message.request))
    waitFor sleepAsync(1)
    check server.cancelActiveRequests("shutdown") == 1
    discard waitFor pending
    check shutdownSeen

suite "nimwire authorization":
  proc authHeaders(methodName: string; toolName = ""): seq[McpHttpHeader] =
    result = @[
      header("Content-Type", "application/json"),
      header("Accept", "application/json, text/event-stream"),
      header("MCP-Protocol-Version", mcpProtocolVersion),
      header("Mcp-Method", methodName)]
    if toolName.len > 0: result.add header("Mcp-Name", toolName)

  test "protects HTTP requests and publishes resource metadata":
    let verifier: McpBearerTokenVerifier = proc (token, resource: string): McpAuthClaims =
      if token notin ["good", "limited"]:
        raise newException(ValueError, "bad token")
      let scopes = if token == "good": @[("read")] else: newSeq[string]()
      newMcpAuthClaims("alice", "https://auth.example", @[resource], scopes,
        epochTime().int64 + 60)
    let authorization = newMcpAuthorizationConfig(
      resource = "https://mcp.example/mcp",
      authorizationServers = @["https://auth.example"],
      scopesSupported = @["read", "write"], requiredScopes = @["read"],
      resourceMetadataUrl = "https://mcp.example/.well-known/oauth-protected-resource/mcp",
      verifier = verifier)
    let config = newMcpHttpConfig(authorization = authorization)
    let server = newMcpServer("auth", "1.0.0")
    server.addTool newMcpTool("whoami", "Caller", %*{"type": "object"},
      proc (args: JsonNode, context: McpContext): McpToolResult =
        textResult(context.principal.subject & ":" & context.principal.scopes[0]))
    let body = modernRequest(150, "tools/call", %*{
      "name": "whoami", "arguments": {}
    })
    var request = newMcpHttpRequest("POST", "/mcp", $body,
      authHeaders("tools/call", "whoami"))
    var response = waitFor server.handleHttpRequest(request, config)
    check response.status == 401
    check response.headers.anyIt(it.name == "WWW-Authenticate" and
      it.value.startsWith("Bearer"))

    request.headers.add header("Authorization", "Bearer limited")
    response = waitFor server.handleHttpRequest(request, config)
    check response.status == 403
    check response.headers.anyIt(it.name == "WWW-Authenticate" and
      it.value.contains("insufficient_scope"))

    request.headers[^1].value = "Bearer bad"
    response = waitFor server.handleHttpRequest(request, config)
    check response.status == 401

    request.headers[^1].value = "Bearer good"
    response = waitFor server.handleHttpRequest(request, config)
    check response.status == 200
    check response.body.parseJson["result"]["content"][0]["text"].getStr ==
      "alice:read"

    let metadata = waitFor server.handleHttpRequest(
      newMcpHttpRequest("GET", "/.well-known/oauth-protected-resource/mcp"), config)
    check metadata.status == 200
    check metadata.body.parseJson["resource"].getStr ==
      "https://mcp.example/mcp"
    check metadata.body.parseJson["authorization_servers"][0].getStr ==
      "https://auth.example"

  test "filters features by principal and validates client metadata":
    let server = newMcpServer("filters", "1.0.0")
    server.addTool newMcpTool("private", "Private", %*{"type": "object"},
      proc (args: JsonNode, ignoredContext: McpContext): McpToolResult = textResult("ok"))
    server.addTool newMcpTool("public", "Public", %*{"type": "object"},
      proc (args: JsonNode, ignoredContext: McpContext): McpToolResult = textResult("ok"))
    server.setToolFilter(proc (name: string, principal: McpPrincipal): bool =
      not principal.isNil and principal.subject == "alice" or name == "public")
    let message = parseMcpMessage(modernRequest(151, "tools/list"))
    var response = waitFor server.handleMessageAsync(message,
      newMcpContext(message.request, principal = newMcpPrincipal("bob")))
    check response.get.response.result.fields["tools"].len == 1
    check response.get.response.result.fields["tools"][0]["name"].getStr == "public"

    server.addResource newMcpResource("memo://private", "Private",
      resourceText("memo://private", "secret"))
    server.addResource newMcpResource("memo://public", "Public",
      resourceText("memo://public", "hello"))
    server.setResourceFilter(proc (uri: string, principal: McpPrincipal): bool =
      uri == "memo://public")
    let resourceList = parseMcpMessage(modernRequest(152, "resources/list"))
    response = waitFor server.handleMessageAsync(resourceList,
      newMcpContext(resourceList.request, principal = newMcpPrincipal("bob")))
    check response.get.response.result.fields["resources"].len == 1
    check response.get.response.result.fields["resources"][0]["uri"].getStr ==
      "memo://public"

    let promptHandler: McpSyncPromptSingleHandler = proc (
        arguments: McpPromptArguments,
        ignoredContext: McpContext): McpPromptMessage = userText("hello")
    server.addPrompt newMcpPrompt("private-prompt", promptHandler)
    server.addPrompt newMcpPrompt("public-prompt", promptHandler)
    server.setPromptFilter(proc (name: string, principal: McpPrincipal): bool =
      name == "public-prompt")
    let promptList = parseMcpMessage(modernRequest(153, "prompts/list"))
    response = waitFor server.handleMessageAsync(promptList,
      newMcpContext(promptList.request, principal = newMcpPrincipal("bob")))
    check response.get.response.result.fields["prompts"].len == 1
    check response.get.response.result.fields["prompts"][0]["name"].getStr ==
      "public-prompt"

    let metadata = parseClientIdMetadata(%*{
      "client_id": "https://client.example",
      "client_name": "Example",
      "redirect_uris": ["https://client.example/callback"],
      "com.example/extension": true
    })
    check metadata.clientName == "Example"
    check metadata.redirectUris.len == 1
    check metadata.extraFields["com.example/extension"].getBool
    expect McpError:
      discard parseClientIdMetadata(%*{"client_id": "not-a-url"})
    expect McpError:
      rejectTokenPassthrough("Bearer secret")

  test "provides bounded output, redaction, and safe URL helpers":
    let redacted = redactJson(%*{
      "authorization": "Bearer secret",
      "nested": {"token": "secret", "visible": true}
    })
    check redacted["authorization"].getStr == "[REDACTED]"
    check redacted["nested"]["token"].getStr == "[REDACTED]"
    check redacted["nested"]["visible"].getBool
    check redactHeaderValue("Cookie", "session=secret") == "[REDACTED]"
    check redactBearerToken("Bearer secret") == "Bearer [REDACTED]"
    check isSafeMcpUrl("https://example.com/consent")
    check not isSafeMcpUrl("http://example.com/consent")
    check not isSafeMcpUrl("https://user:pass@example.com/consent")
    expect McpError:
      discard newMcpElicitationUrlRequest("Consent", "http://example.com")

    let limited = newMcpServer("limits", "1.0.0")
    limited.setSecurityLimits(newMcpSecurityLimits(maxToolCount = 1,
      maxContentBytes = 12))
    limited.addTool newMcpTool("one", "One", %*{"type": "object"},
      proc (args: JsonNode, ignoredContext: McpContext): McpToolResult =
        textResult("this output is too long"))
    expect McpError:
      limited.addTool newMcpTool("two", "Two", %*{"type": "object"},
        proc (args: JsonNode, ignoredContext: McpContext): McpToolResult =
          textResult("ok"))
    let response = limited.handleJson(modernRequest(160, "tools/call", %*{
      "name": "one", "arguments": {}
    }))
    check response["error"]["code"].getInt == mcpInvalidParamsCode

suite "nimwire observability":
  test "emits structured request events and independent spans":
    let server = newMcpServer("observed", "1.0.0")
    var logs: seq[McpRequestEvent]
    var metricEvents: seq[McpRequestEvent]
    var spansStarted = 0
    var spansEnded = 0
    let requestLog: McpRequestLogHook = proc (event: McpRequestEvent) =
      logs.add event
    let metrics: McpMetricsHook = proc (event: McpRequestEvent) =
      metricEvents.add event
    let spanStart: McpSpanStartHook = proc (
        event: McpRequestEvent): McpSpanHandle =
      inc spansStarted
      McpSpanHandle(state: %*{"correlationId": event.correlationId})
    let spanEnd: McpSpanEndHook = proc (span: McpSpanHandle,
                                        event: McpRequestEvent) =
      inc spansEnded
      check span.state["correlationId"].getStr == event.correlationId
    let hooks = McpObservability(requestLog: requestLog, metrics: metrics,
      spanStart: spanStart, spanEnd: spanEnd)
    server.setObservability(hooks)

    var request = modernRequest(170, "ping")
    request["params"]["_meta"][mcpMetaTraceContextKey] = %*{
      "traceparent": "00-abc-def-01",
      "tracestate": "vendor=value",
      "baggage": "tenant=demo"
    }
    request["params"]["_meta"][mcpMetaLogLevelKey] = %"warning"
    let response = server.handleJson(request)
    check response["result"]["resultType"].getStr == "complete"
    check logs.len == 1
    check metricEvents.len == 1
    check spansStarted == 1
    check spansEnded == 1
    let event = logs[0]
    check event.requestId.integerValue == 170
    check event.correlationId.len > 0
    check event.correlationId != "170"
    check event.methodName == "ping"
    check event.transport.kind == mcpTransportUnknown
    check event.hasTraceContext
    check event.traceContext.traceparent == "00-abc-def-01"
    check event.traceContext.tracestate == "vendor=value"
    check event.traceContext.baggage == "tenant=demo"
    check event.hasLogLevel and event.logLevel == mcpLogWarning
    check event.durationMs >= 0
    check event.requestBytes == ($request).len
    check event.responseBytes > 0
    check event.hasResultType and event.resultType == mcpComplete
    check event.errorCode == 0
    check not event.cancelled
    check event.activeSubscriptions == 0
    let encoded = toJson(event)
    check encoded["correlationId"].getStr == event.correlationId
    check encoded["requestId"].getInt == 170
    check encoded["transport"].getStr == "unknown"
    check encoded["traceContext"]["baggage"].getStr == "tenant=demo"
    check encoded["logLevel"].getStr == "warning"
    check encoded["resultType"].getStr == "complete"

  test "treats request logLevel as the logger minimum":
    var request = modernRequest(172, "ping")
    request["params"]["_meta"][mcpMetaLogLevelKey] = %"warning"
    let parsed = parseMcpMessage(request)
    var levels: seq[McpLogLevel]
    let logger: McpLogger = proc (level: McpLogLevel, message: string) =
      levels.add level
    let context = newMcpContext(parsed.request, logger = logger)
    context.log(mcpLogInfo, "hidden")
    context.log(mcpLogWarning, "shown")
    context.log(mcpLogError, "shown")
    check levels == @[mcpLogWarning, mcpLogError]

  test "records cancellation and protocol error codes":
    let server = newMcpServer("observed-cancel", "1.0.0")
    var events: seq[McpRequestEvent]
    server.setObservability(McpObservability(
      metrics: proc (event: McpRequestEvent) = events.add event))
    server.addTool newMcpTool("slow", "Slow", %*{"type": "object"},
      proc (args: JsonNode, context: McpContext): Future[McpToolResult] {.async.} =
        await sleepAsync(20)
        context.checkCancelled()
        textResult("done"))
    let message = parseMcpMessage(modernRequest(173, "tools/call", %*{
      "name": "slow", "arguments": {}
    }))
    let context = newMcpContext(message.request)
    let pending = server.handleMessageAsync(message, context)
    waitFor sleepAsync(1)
    check server.cancelRequest(message.request.id, "client left")
    discard waitFor pending
    check events.len == 1
    check events[0].cancelled
    check events[0].errorCode == mcpRequestCancelledCode

suite "nimwire tasks and extensions":
  proc taskRequest(id: int, methodName: string,
                   params: JsonNode = newJObject()): JsonNode =
    result = modernRequest(id, methodName, params)
    result["params"]["_meta"][mcpMetaClientCapabilitiesKey]["extensions"] =
      %*{mcpTasksExtensionName: {}}

  proc taskHttpHeaders(methodName, name: string): seq[McpHttpHeader] =
    @[
      header("Content-Type", "application/json"),
      header("Accept", "application/json, text/event-stream"),
      header("MCP-Protocol-Version", mcpProtocolVersion),
      header("Mcp-Method", methodName),
      header("Mcp-Name", name)]

  test "advertises tasks and polls a completed task":
    let server = newMcpServer("tasks", "1.0.0")
    server.enableTasks(newMcpTaskStore(pollIntervalMs = 1))
    server.addTool newMcpTaskTool("slow", "Slow task", %*{
      "type": "object"
    }, proc (args: JsonNode, context: McpContext): Future[McpWireResult] {.async.} =
      await context.reportProgress(0.5, 1.0, "halfway")
      await sleepAsync(5)
      newMcpResult(mcpComplete, %*{
        "content": [{"type": "text", "text": "done"}],
        "isError": false
      }))

    var response = server.handleJson(modernRequest(180, "server/discover"))
    check response["result"]["capabilities"]["extensions"][
      mcpTasksExtensionName].kind == JObject
    let missing = server.handleJson(modernRequest(181, "tools/call", %*{
      "name": "slow", "arguments": {}
    }))
    check missing["error"]["code"].getInt ==
      mcpMissingRequiredClientCapabilityCode
    check missing["error"]["data"]["requiredCapabilities"]["extensions"][
      mcpTasksExtensionName].kind == JObject

    response = server.handleJson(taskRequest(182, "tools/call", %*{
      "name": "slow", "arguments": {}
    }))
    check response["result"]["resultType"].getStr == "task"
    let taskId = response["result"]["taskId"].getStr
    check taskId.startsWith("nimwire.task.")
    waitFor sleepAsync(10)
    response = server.handleJson(taskRequest(183, "tasks/get", %*{
      "taskId": taskId
    }))
    check response["result"]["resultType"].getStr == "complete"
    check response["result"]["status"].getStr == "completed"
    check response["result"]["progress"].getFloat == 0.5
    check response["result"]["total"].getFloat == 1.0
    check response["result"]["result"]["content"][0]["text"].getStr == "done"

  test "routes task polling with the Streamable HTTP task header":
    let server = newMcpServer("task-http", "1.0.0")
    server.enableTasks()
    server.addTool newMcpTaskTool("http-task", "HTTP task", %*{
      "type": "object"
    }, proc (args: JsonNode, context: McpContext): Future[McpWireResult] {.async.} =
      newMcpResult(mcpComplete, %*{"content": [], "isError": false}))
    let body = taskRequest(201, "tools/call", %*{
      "name": "http-task", "arguments": {}
    })
    var response = waitFor server.handleHttpRequest(newMcpHttpRequest(
      "POST", "/mcp", $body, taskHttpHeaders("tools/call", "http-task")))
    check response.status == 200
    let taskId = response.body.parseJson["result"]["taskId"].getStr
    let poll = taskRequest(202, "tasks/get", %*{"taskId": taskId})
    response = waitFor server.handleHttpRequest(newMcpHttpRequest(
      "POST", "/mcp", $poll, taskHttpHeaders("tasks/get", taskId)))
    check response.status == 200
    check response.body.parseJson["result"]["status"].getStr == "completed"
    response = waitFor server.handleHttpRequest(newMcpHttpRequest(
      "POST", "/mcp", $poll, taskHttpHeaders("tasks/get", "wrong")))
    check response.status == 400
    check response.body.parseJson["error"]["code"].getInt ==
      mcpHeaderMismatchCode

  test "supports durable stores and expires task handles":
    var saved: McpTask
    let durable = newMcpTaskStoreBackend(
      proc (task: McpTask) = saved = task,
      proc (taskId, subject: string): McpTask =
        if not saved.isNil and saved.taskId == taskId and saved.owner == subject:
          saved
        else:
          nil,
      proc (task: McpTask) = saved = task)
    let server = newMcpServer("durable-tasks", "1.0.0")
    server.enableTasks(durable)
    server.addTool newMcpTaskTool("stored", "Stored task", %*{
      "type": "object"
    }, proc (args: JsonNode, context: McpContext): Future[McpWireResult] {.async.} =
      newMcpResult(mcpComplete, %*{"content": [], "isError": false}))
    let created = server.handleJson(taskRequest(197, "tools/call", %*{
      "name": "stored", "arguments": {}
    }))
    check not saved.isNil
    check saved.taskId == created["result"]["taskId"].getStr
    waitFor sleepAsync(1)
    let fetched = server.handleJson(taskRequest(198, "tasks/get", %*{
      "taskId": saved.taskId
    }))
    check fetched["result"]["status"].getStr == "completed"

    let expiring = newMcpServer("expiring-tasks", "1.0.0")
    expiring.enableTasks(newMcpTaskStore(ttlMs = 1))
    expiring.addTool newMcpTaskTool("short", "Short task", %*{
      "type": "object"
    }, proc (args: JsonNode, context: McpContext): Future[McpWireResult] {.async.} =
      newMcpResult(mcpComplete, %*{"content": [], "isError": false}))
    let short = expiring.handleJson(taskRequest(199, "tools/call", %*{
      "name": "short", "arguments": {}
    }))
    waitFor sleepAsync(10)
    let expired = expiring.handleJson(taskRequest(200, "tasks/get", %*{
      "taskId": short["result"]["taskId"].getStr
    }))
    check expired["error"]["code"].getInt == mcpInvalidParamsCode

  test "moves tasks through input, update, and cancellation":
    let server = newMcpServer("task-flow", "1.0.0")
    server.enableTasks()
    server.addTool newMcpTaskTool("input", "Needs input", %*{
      "type": "object"
    }, proc (args: JsonNode, context: McpContext): Future[McpWireResult] {.async.} =
      if context.inputResponses.len == 0:
        newMcpResult(mcpInputRequired, %*{
          "inputRequests": {
            "name": {"method": "elicitation/create", "params": {
              "mode": "form", "message": "Name", "requestedSchema": {
                "type": "object", "properties": {"name": {"type": "string"}}
              }
            }}
          }
        })
      else:
        newMcpResult(mcpComplete, %*{
          "content": [{"type": "text",
                        "text": context.inputResponse("name")["content"]["name"].getStr}],
          "isError": false
        }))
    let created = server.handleJson(taskRequest(184, "tools/call", %*{
      "name": "input", "arguments": {}
    }))
    let taskId = created["result"]["taskId"].getStr
    waitFor sleepAsync(1)
    var response = server.handleJson(taskRequest(185, "tasks/get", %*{
      "taskId": taskId
    }))
    check response["result"]["status"].getStr == "input_required"
    check response["result"]["inputRequests"]["name"].kind == JObject
    response = server.handleJson(taskRequest(186, "tasks/update", %*{
      "taskId": taskId,
      "inputResponses": {"name": {"action": "accept",
        "content": {"name": "Ada"}}}
    }))
    check response["result"]["resultType"].getStr == "complete"
    waitFor sleepAsync(1)
    response = server.handleJson(taskRequest(187, "tasks/get", %*{
      "taskId": taskId
    }))
    check response["result"]["status"].getStr == "completed"
    check response["result"]["result"]["content"][0]["text"].getStr == "Ada"

    server.addTool newMcpTaskTool("cancel", "Cancellable", %*{
      "type": "object"
    }, proc (args: JsonNode, context: McpContext): Future[McpWireResult] {.async.} =
      await sleepAsync(50)
      context.checkCancelled()
      newMcpResult(mcpComplete, %*{"content": [], "isError": false}))
    let cancellable = server.handleJson(taskRequest(188, "tools/call", %*{
      "name": "cancel", "arguments": {}
    }))
    let cancellableId = cancellable["result"]["taskId"].getStr
    discard server.handleJson(taskRequest(189, "tasks/cancel", %*{
      "taskId": cancellableId
    }))
    response = server.handleJson(taskRequest(190, "tasks/get", %*{
      "taskId": cancellableId
    }))
    check response["result"]["status"].getStr == "cancelled"

  test "records task failures for later retrieval":
    let server = newMcpServer("failed-tasks", "1.0.0")
    server.enableTasks()
    server.addTool newMcpTaskTool("failed", "Failed task", %*{
      "type": "object"
    }, proc (args: JsonNode, context: McpContext): Future[McpWireResult] {.async.} =
      raise newMcpError("task failed", mcpInvalidParamsCode, %*{
        "reason": "test"
      }))
    let created = server.handleJson(taskRequest(203, "tools/call", %*{
      "name": "failed", "arguments": {}
    }))
    waitFor sleepAsync(1)
    let response = server.handleJson(taskRequest(204, "tasks/get", %*{
      "taskId": created["result"]["taskId"].getStr
    }))
    check response["result"]["status"].getStr == "failed"
    check response["result"]["error"]["code"].getInt == mcpInvalidParamsCode
    check response["result"]["error"]["data"]["reason"].getStr == "test"

  test "finalizes generic extensions and dispatches their schemas":
    let server = newMcpServer("extensions", "1.0.0")
    let extension = newMcpExtension("com.example/demo",
      capabilities = %*{"version": 1},
      metadata = %*{"com.example/serverMode": "demo"},
      requiresClientCapability = true)
    extension.addExtensionMethod("com.example/echo",
      proc (params: JsonNode, context: McpContext): Future[McpWireResult] {.async.} =
        newMcpResult(mcpComplete, %*{"echo": params["value"]}),
      inputSchema = %*{"type": "object", "required": ["value"],
                       "properties": {"value": {"type": "string"}}},
      outputSchema = %*{"type": "object", "required": ["echo"]},
      transportRules = %*{"Mcp-Name": "optional"})
    server.registerExtension(extension)
    check server.draftExtensions.len == 1
    check server.finalizedExtensions.len == 0
    server.finalizeExtension("com.example/demo")
    check server.draftExtensions.len == 0
    check server.finalizedExtensions.len == 1
    var response = server.handleJson(modernRequest(191, "server/discover"))
    check response["result"]["capabilities"]["extensions"][
      "com.example/demo"]["version"].getInt == 1
    check response["result"]["_meta"]["com.example/serverMode"].getStr == "demo"
    let missing = server.handleJson(modernRequest(192, "com.example/echo", %*{
      "value": "x"
    }))
    check missing["error"]["code"].getInt ==
      mcpMissingRequiredClientCapabilityCode
    var request = modernRequest(193, "com.example/echo", %*{"value": "x"})
    request["params"]["_meta"][mcpMetaClientCapabilitiesKey]["extensions"] =
      %*{"com.example/demo": {}}
    response = server.handleJson(request)
    check response["result"]["echo"].getStr == "x"
    request = modernRequest(194, "com.example/echo", %*{"value": 1})
    request["params"]["_meta"][mcpMetaClientCapabilitiesKey]["extensions"] =
      %*{"com.example/demo": {}}
    response = server.handleJson(request)
    check response["error"]["code"].getInt == mcpInvalidParamsCode

  test "scopes task handles to their authenticated principal":
    let server = newMcpServer("task-scope", "1.0.0")
    server.enableTasks()
    server.addTool newMcpTaskTool("owned", "Owned task", %*{
      "type": "object"
    }, proc (args: JsonNode, context: McpContext): Future[McpWireResult] {.async.} =
      newMcpResult(mcpComplete, %*{"content": [], "isError": false}))
    let request = taskRequest(195, "tools/call", %*{
      "name": "owned", "arguments": {}
    })
    let message = parseMcpMessage(request)
    let created = waitFor server.handleMessageAsync(message,
      newMcpContext(message.request, principal = newMcpPrincipal("alice")))
    let taskId = created.get.response.result.fields["taskId"].getStr
    let getRequest = parseMcpMessage(taskRequest(196, "tasks/get", %*{
      "taskId": taskId
    }))
    let denied = waitFor server.handleMessageAsync(getRequest,
      newMcpContext(getRequest.request,
        principal = newMcpPrincipal("bob")))
    check denied.get.errorResponse.error.code == mcpInvalidParamsCode
