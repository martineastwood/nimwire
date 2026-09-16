---
title: Prompts
description: Define typed prompt arguments, messages, and completions.
---

Prompts are reusable message templates. A client discovers them with `prompts/list` and requests messages with `prompts/get`.

## Define a prompt

```nim
import nimwire

let server = mcpServer("review", "1.0.0"):
  server.addPrompt mcpPrompt(
    "review",
    proc (arguments: McpPromptArguments,
          context: McpContext): McpPromptMessage =
      userText("Review this code:\n" &
        getPromptArgument(arguments, "code")),
    description = "Review a code snippet",
    arguments = @[newMcpPromptArgument("code", required = true)])

server.serveStdio()
```

Prompt arguments are strings. Mark an argument as `required` to make nimwire reject `prompts/get` requests that omit it. `getPromptArgument` raises a protocol error for a missing required argument, or returns an empty string when called with `required = false`.

The handler can return one `McpPromptMessage` or a sequence of messages. Use `userText` and `assistantText` for text, or build messages with `userPrompt` and `assistantPrompt` when you need media or resources.

## Return other content

Prompt content supports:

- `textContent` for UTF-8 text;
- `imageContent` and `audioContent` for base64 media with a MIME type;
- `resourceLinkContent` for a link to a resource; and
- `embeddedResourceContent` for text or blob content inside the message.

Construct the content, then pass it to `userPrompt` or `assistantPrompt`. nimwire validates the content shape before it is sent to the client.

## Add completions

Completions help a client fill a prompt argument:

```nim
let completionHandler: McpSyncPromptCompletionHandler = proc (
    argument, prefix: string,
    context: McpContext): seq[string] =
  discard argument
  discard context
  @[prefix & " example"]

server.addPromptCompletion("review", "code", completionHandler)
```

The same completion API accepts an async handler or a reusable `mcpCompletion` value. A completion request can include prior argument values in `context.completionArguments`.

The server accepts `ref/prompt` and `ref/resource` completion references and returns at most 100 suggestions. The response includes the untrimmed `total` and a `hasMore` flag.

## Change notifications

Call `server.markPromptsChanged()` when the prompt list changes. Enable a list-changed capability during discovery by calling this before clients discover the server. Use [Subscriptions](/guides/subscriptions/) when clients need a live change stream.

Related: [Resources](/guides/resources/) and the [prompts API reference](/reference/api/nimwire/prompts/).
