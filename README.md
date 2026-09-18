# nimwire

MCP server library for Nim. Expose tools, resources, and prompts from native
code, then serve them over stdio, Streamable HTTP, or WebSocket.

nimwire targets the MCP `2026-07-28` revision. You write ordinary Nim
procedures; nimwire handles discovery, JSON Schema, protocol framing, and the
transport you choose. No hosted service required.

## Install

You need Nim 2.0 or later:

```sh
nimble install nimwire
```

## Hello, MCP

Create `echo.nim`:

```nim
import nimwire

type EchoInput = object
  text*: string

let server = mcpServer("nimwire-echo", "0.1.0"):
  server.tool "echo", "Echo text back to the caller",
    proc (input: EchoInput): string =
      input.text

server.serveStdio()
```

Compile and run from an interactive terminal:

```sh
nim c -r echo.nim
```

The executable reads newline-delimited JSON-RPC from stdin and writes responses
to stdout. MCP clients normally launch it for you. The
[quickstart](https://nimwire.niminal.dev/guides/quickstart/) shows how to send
your first request.

## Typed tools

Write a Nim procedure and let nimwire derive the MCP input and output schemas:

```nim
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

Handlers can also receive request context, report progress, honor cancellation,
and return async `Future[T]` values when the work is I/O bound.

## Publish a resource

Resources give clients read-only data identified by a URI:

```nim
import nimwire

let server = mcpServer("notes", "1.0.0"):
  server.addResource newMcpResource(
    "memo://today",
    "Today's memo",
    resourceText("memo://today", "Ship it", "text/plain"))

server.serveStdio()
```

You can serve static text, generated data, binary contents, confined files, and
URI templates. See the [resources guide](https://nimwire.niminal.dev/guides/resources/)
for file access and on-demand handlers.

## Offer a prompt

Prompts return reusable messages built from typed string arguments:

```nim
import nimwire

let server = mcpServer("review", "1.0.0"):
  server.addPrompt mcpPrompt("review",
    proc (arguments: McpPromptArguments,
          ignoredContext: McpContext): McpPromptMessage =
      userText("Review this code:\n" & getPromptArgument(arguments, "code")),
    description = "Review a code snippet",
    arguments = @[newMcpPromptArgument("code", required = true)])

server.serveStdio()
```

## Serve over HTTP

The same server can accept remote clients with Streamable HTTP:

```nim
import std/[asyncdispatch, json, nativesockets]
import nimwire

let app = mcpServer("http-example", "1.0.0"):
  server.addTool mcpTool("echo", "Echo text", %*{
    "type": "object",
    "properties": {"text": {"type": "string"}},
    "required": ["text"]
  }, proc (args: JsonNode, ignoredContext: McpContext): McpToolResult =
    textResult(args["text"].getStr))

let http = newMcpHttpServer(app, newMcpHttpConfig(
  endpoint = "/mcp", host = "127.0.0.1", port = Port(8080),
  allowedHosts = @["127.0.0.1"]))

waitFor http.serveHttp()
```

Run it with `nim c -r http.nim`, then connect to `http://127.0.0.1:8080/mcp`.
WebSocket and in-process transports are available too. See
[transports](https://nimwire.niminal.dev/guides/transports/) for stdio, HTTP,
WebSocket, and composition.

## What you get

- **Typed tools:** derive MCP schemas from Nim types, or provide raw JSON when
  you need full control.
- **Resources and prompts:** publish data and reusable messages with optional
  completion hooks.
- **Transports:** stdio for local clients, Streamable HTTP and WebSocket for
  remote ones, in-process linking for tests and composition.
- **Long-running work:** opt into MCP Tasks, progress, cancellation, and
  deadlines.
- **Multi-round-trip input:** pause a call with `input_required` and resume on
  the next request.
- **Production controls:** bearer authorization, principal-based visibility,
  security limits, request logs, metrics, and tracing hooks.

Runnable examples live in [`examples/`](examples/).

## Documentation

Full documentation lives at **[nimwire.niminal.dev](https://nimwire.niminal.dev)**.

- [Introduction](https://nimwire.niminal.dev/introduction/)
- [Quickstart](https://nimwire.niminal.dev/guides/quickstart/)
- [Server basics](https://nimwire.niminal.dev/guides/server-basics/)
- [Typed tools](https://nimwire.niminal.dev/guides/tools/)
- [Resources](https://nimwire.niminal.dev/guides/resources/)
- [Prompts](https://nimwire.niminal.dev/guides/prompts/)
- [Transports](https://nimwire.niminal.dev/guides/transports/)
- [Multi-round-trip input](https://nimwire.niminal.dev/guides/mrtr/)
- [Security](https://nimwire.niminal.dev/guides/security/)
- [Examples](https://nimwire.niminal.dev/examples/)
- [Core API](https://nimwire.niminal.dev/reference/core-api/)

## License

MIT. See [LICENSE](LICENSE).
