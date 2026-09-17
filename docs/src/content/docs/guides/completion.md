---
title: Completion
description: Help clients fill prompt arguments and resource template variables.
---

Completion suggests values while a user is filling in a prompt argument or a resource template variable. Clients call `completion/complete` with either a prompt reference or a resource-template reference.

## Complete a prompt argument

Attach a handler when you register the prompt:

```nim
import nimwire

let server = mcpServer("review", "1.0.0"):
  server.addPrompt mcpPrompt(
    "review",
    proc (arguments: McpPromptArguments,
          context: McpContext): McpPromptMessage =
      userText("Review this code:\n" &
        getPromptArgument(arguments, "code")),
    arguments = @[newMcpPromptArgument("code", required = true)])

server.addPromptCompletion("review", "code",
  proc (argument, prefix: string, context: McpContext): seq[string] =
    discard argument
    discard context
    @[prefix & " example", prefix & " fixture"])
```

The handler receives the argument name, the current prefix, and request context. Return up to 100 suggestions. nimwire includes the untrimmed `total` and a `hasMore` flag in the response.

You can also register a reusable completion value with `mcpCompletion`, or use an async handler when suggestions come from I/O.

## Complete a resource template variable

Resource templates use the same completion shape. Register the handler after adding the template:

```nim
let template = mcpResourceTemplate(
  "memo://{date}",
  "Daily memo",
  proc (uri: string, arguments: JsonNode,
        context: McpContext): McpResourceContent =
    resourceText(uri, "Memo for " & arguments["date"].getStr, "text/plain"))

server.addResourceTemplate(template)
server.addResourceTemplateCompletion("memo://{date}", "date",
  proc (argument, prefix: string, context: McpContext): seq[string] =
    discard argument
    @["2026-09-17", "2026-09-18"])
```

`resourceTemplateVariables` lists the variable names in a template. `matchResourceTemplate` decodes values when a concrete URI matches.

## Use prior argument values

When a client sends partial prompt arguments, earlier values are available on the context:

```nim
server.addPromptCompletion("deploy", "environment",
  proc (argument, prefix: string, context: McpContext): seq[string] =
    let region = if "region" in context.completionArguments:
      context.completionArguments["region"].getStr else: ""
    if region == "eu":
      @["staging-eu", "prod-eu"]
    else:
      @["staging", "prod"])
```

Completion references use `ref/prompt` or `ref/resource` on the wire. The server validates the reference, dispatches your handler, and caps the result list at 100 values.

Related: [Prompts](/guides/prompts/), [Resources](/guides/resources/), and the [server API reference](/reference/api/nimwire/server/).
