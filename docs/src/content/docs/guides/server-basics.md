---
title: Server basics
description: Register MCP tools and shape their responses.
---

Start with an `McpServer`, register the features it exposes, then attach a transport. The server accepts MCP requests such as `server/discover`, `tools/list`, and `tools/call`.

## Create a server

```nim
import nimwire

let server = newMcpServer(
  "weather", "1.0.0",
  instructions = "Use the weather tool for current conditions.")
```

The name and version are required. `instructions` is included in discovery so a client can understand the server's purpose.

The `mcpServer` template is a shorter form when registration should stay next to construction:

```nim
let server = mcpServer("weather", "1.0.0"):
  discard
```

## Register a raw tool

Use `mcpTool` when the handler naturally works with JSON:

```nim
import std/[json, strutils]

server.addTool mcpTool("word_count", "Count words in text", %*{
  "type": "object",
  "properties": {"text": {"type": "string"}},
  "required": ["text"],
  "additionalProperties": false
}, proc (args: JsonNode, context: McpContext): McpToolResult =
  textResult($args["text"].getStr.splitWhitespace.len))
```

The second handler parameter is request context. Name it `ignoredContext` when the handler does not need it. A handler can be synchronous or return `Future[McpToolResult]`.

Tool names are 1 to 128 characters and may contain letters, numbers, `_`, `-`, and `.`. Names must be unique after registration.

## Return text or JSON

Use the result that matches what the client should receive:

```nim
textResult("ready")
jsonResult(%*{"temperature": 16, "unit": "C"})
structuredResult(%*{"temperature": 16, "unit": "C"})
```

`textResult` creates a text content item. `jsonResult` and `structuredResult` include structured content as well as a readable text representation. Set `isError = true` when a tool completed but its result describes a tool failure.

## Return images, audio, and resources

Tools can return multiple content blocks. Build an array and pass it to `newMcpToolResult`:

```nim
newMcpToolResult(@[
  textContent("Screenshot attached"),
  imageContent(base64Image, "image/png"),
  resourceLinkContent("file:///tmp/report.txt", "report",
    mimeType = "text/plain")])
```

Use `audioContent` for audio blocks and `embeddedResourceContent` when the payload should travel inline. These helpers match the content shapes used by prompts.

## Add presentation metadata

Tools can expose a display title, icons, and caller-facing annotations in discovery:

```nim
server.addTool newMcpTool(
  "weather", "Get current weather", inputSchema, handler,
  title = "Current weather",
  icons = %*[{"src": "https://example.com/weather.svg"}],
  annotations = %*{"readOnlyHint": true})
```

`title`, `icons`, and `annotations` are validated at registration time. Do not use annotations as an authorization policy. Use [Security](/guides/security/) filters for access control instead.

For typed failures, return `McpResult[T]`:

```nim
proc lookup(code: string): McpResult[string] =
  if code.len == 0:
    return mcpResultError[string]("invalid_code", "A code is required")
  mcpResult("result for " & code)
```

`mcpFailure[T](message)` is a shorthand for the `tool_error` code. Set `retryable = true` when retry middleware or a client may safely try again.

## Group tools

Namespaces make related tools easier to discover and prevent name collisions:

```nim
var admin = newMcpToolGroup("admin")
admin.addTool mcpTool("reload", "Reload configuration", %*{"type": "object"},
  proc (args: JsonNode, context: McpContext): McpToolResult = textResult("ok"))
server.addToolGroup(admin)
```

The tool is exposed as `admin.reload`. You can also use `server.addTools("admin", tools)`.

## Discovery and pagination

Discovery is sorted by final name, regardless of registration order. Set `listPageSize` in `newMcpServer` when a list should be paginated, for example `listPageSize = 25`. The client follows `nextCursor` values until it has the complete list.

`listTtlMs` and `listCacheScope` add cache hints to list and resource-read responses. `listCacheScope` must be `"public"` or `"private"`.

Related: [Typed tools](/guides/tools/), [Resources](/guides/resources/), and the [server API reference](/reference/api/nimwire/server/).
