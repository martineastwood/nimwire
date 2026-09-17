---
title: Typed tools
description: Derive MCP schemas from Nim procedures and types.
---

Typed tools let you write normal Nim procedures while nimwire generates the MCP input schema and decodes the arguments before your handler runs.

## Define a typed tool

```nim
import std/json
import nimwire

type Weather = object
  temperature*: int
  condition*: string

let server = mcpServer("weather", "1.0.0"):
  server.tool "weather", "Get current weather for a city",
    proc (city: string): Weather =
      discard city
      Weather(temperature: 16, condition: "cloudy")

server.serveStdio()
```

The `city` parameter becomes a required string property. The `Weather` return type becomes the tool's `outputSchema`, and the returned value is encoded as structured content.

The typed macro also accepts request helpers as parameters:

```nim
server.tool "audit", "Record an audit event",
  proc (message: string, context: McpContext): string =
    context.log(mcpLogInfo, message)
    "recorded"
```

You can receive one `McpContext`, `McpCancellation`, `McpProgressReporter`, or `McpLogger` parameter. Those parameters are supplied by nimwire and do not appear in the input schema.

Handlers can also return `Future[T]`, `Future[McpToolResult]`, or `Future[McpResult[T]]` when the work is asynchronous:

```nim
import std/[asyncdispatch, json]

server.tool "fetch", "Fetch remote data",
  proc (url: string): Future[string] {.async.} =
    await sleepAsync(10)
    "fetched " & url
```

## Debug macro expansion

When a typed tool fails to compile or the generated schema looks wrong, compile with `-d:mcpwireDebugMacros`. nimwire prints the registration code the `tool` macro generated.

## Supported types

Schema derivation supports:

- strings, booleans, integers, and floating-point values;
- objects and nested objects;
- sequences and arrays;
- string-keyed `Table` and `OrderedTable` values;
- enums, encoded as string enums; and
- `Option[T]`, represented as a value or `null` and omitted from `required`.

Typed parameters cannot use Nim defaults. Use `Option[T]` when an argument is optional. A typed object is closed by default, so unknown properties are rejected before the handler runs.

## Override a schema

Use `inputSchema` or `outputSchema` when the wire contract needs details that type derivation does not express:

```nim
import std/json

server.tool "temperature", "Read a temperature",
  proc (city: string): float = 16.0,
  inputSchema = %*{
    "type": "object",
    "properties": {"city": {"type": "string", "minLength": 1}},
    "required": ["city"],
    "additionalProperties": false
  }
```

Use `mcpJsonSchema(MyType)` when the same generated schema is needed for another registration or validation boundary.

## Structured errors

Return `McpResult[T]` when the caller needs a stable error code and details:

```nim
type Lookup = object
  value*: string

server.tool "lookup", "Look up a value",
  proc (key: string): McpResult[Lookup] =
    if key == "":
      return mcpResultError[Lookup]("missing_key", "key is required")
    mcpResult(Lookup(value: key))
```

The success value is structured content. At the tool boundary, a typed error becomes an `isError` result with the message as readable text. Its `retryable` flag is preserved for retry middleware. If the client needs structured error fields on the wire, return them explicitly with `jsonResult` or `newMcpToolResult`.

## Headers mirrored from arguments

HTTP tool calls can mirror a statically reachable string, integer, or boolean property into `Mcp-Param-{name}`. Add `x-mcp-header` to that property in the input schema. nimwire checks that the header and JSON body agree. See [Transports](/guides/transports/) for the HTTP envelope.

Related: [Server basics](/guides/server-basics/) and the [schema API reference](/reference/api/nimwire/schema/).
