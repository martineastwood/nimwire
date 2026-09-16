---
title: Prompts server
description: Define a prompt with a required argument and completion hook.
---

This server exposes a `review` prompt. Its `code` argument is required, and completion returns a suggestion based on the typed prefix.

```nim
import ../src/nimwire

let server = mcpServer("prompt-example", "1.0.0"):
  let reviewHandler: McpSyncPromptSingleHandler = proc (
      arguments: McpPromptArguments,
      ignoredContext: McpContext): McpPromptMessage =
    userText("Review this code:\n" & getPromptArgument(arguments, "code"))
  server.addPrompt mcpPrompt("review", reviewHandler,
    description = "Review a code snippet",
    arguments = @[newMcpPromptArgument("code", required = true)])

  let completionHandler: McpSyncPromptCompletionHandler = proc (
      argument, prefix: string,
      ignoredContext: McpContext): seq[string] = @[prefix & " example"]
  server.addPromptCompletion("review", "code", completionHandler)

server.serveStdio()
```

Compile it from the package directory:

```sh
nim c examples/prompts_server.nim
```

[View the source example](https://github.com/martineastwood/nimwire/blob/main/examples/prompts_server.nim)
