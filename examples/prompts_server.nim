## Prompt example with typed arguments and a completion hook.

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
