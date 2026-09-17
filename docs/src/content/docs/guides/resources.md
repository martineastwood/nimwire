---
title: Resources
description: Serve static data, generated contents, files, and URI templates.
---

Resources give an MCP client read-only data identified by a URI. The URI must include a scheme, such as `memo://today`, `file:///project/README.md`, or `https://example.com/data.json`.

## Add static text

```nim
import nimwire

let server = newMcpServer("notes", "1.0.0")
server.addResource newMcpResource(
  "memo://today",
  "Today's memo",
  resourceText("memo://today", "Ship it", "text/plain"))
```

`resourceText` validates the URI and UTF-8 text. `resourceBlob` accepts base64 data, while `resourceBytes` base64-encodes a Nim string for you:

```nim
import std/os

let binaryData = readFile("logo.png")

server.addResource newMcpResource(
  "image://logo",
  "Logo",
  resourceBytes("image://logo", binaryData, "image/png"))
```

You can set a default `mimeType`, `description`, `size`, `title`, `icons`, and caller-facing `annotations` on the resource.

## Generate data when it is read

Use a handler for data that should be fetched or calculated on demand:

```nim
import std/[asyncdispatch, json]

let generated: McpResourceReadHandler = proc (uri: string,
    context: McpContext): Future[seq[McpResourceContent]] {.async.} =
  discard context
  @[
    resourceText(uri, $(%*{"healthy": true}), "application/json")]

server.addResource newMcpResource(
  "data://health", "Health report", generated,
  mimeType = "application/json")
```

Synchronous handlers are also accepted. A handler may return one content value or a sequence of values.

## Confine file access

`newFileResource` exposes one existing file under a root directory:

```nim
import std/os

server.addResource newFileResource(
  getCurrentDir(),
  "README.md",
  uriValue = "file:///project/README.md",
  mimeType = "text/markdown")
```

The path is checked before it is read. `safeResourcePath` rejects traversal, symlink escapes, empty paths, and paths outside the configured root. Use `binary = true` for a binary file.

For parameterized files, use `newFileResourceTemplate(root, uriTemplate, name)`. The template must contain the configured path argument, which defaults to `path`.

## Use URI templates

```nim
let memoTemplate = mcpResourceTemplate(
  "memo://{date}",
  "Daily memo",
  proc (uri: string, arguments: JsonNode,
        context: McpContext): McpResourceContent =
    resourceText(uri, "Memo for " & arguments["date"].getStr,
      "text/plain"))

server.addResourceTemplate(memoTemplate)
```

`resourceTemplateVariables` lists the variable names, and `matchResourceTemplate` returns decoded values when a URI matches. One variable is supported in each template expression.

## Completions

Attach a completion handler with `server.addResourceTemplateCompletion`. See [Completion](/guides/completion/) for prompt and resource completion patterns, prior-argument values, and response limits.

Call `server.markResourcesChanged()` after adding or removing resources from the application view. Call `server.markResourceUpdated(uri)` when the contents of one URI changed. See [Subscriptions](/guides/subscriptions/) for delivering those notifications.

Related: [Prompts](/guides/prompts/) and the [resources API reference](/reference/api/nimwire/resources/).
