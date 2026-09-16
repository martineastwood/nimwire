---
title: Auth server
description: Protect an HTTP endpoint with bearer authorization and scopes.
---

The auth example supports public mode, bearer mode, and bearer mode with a required `read` scope. Its verifier accepts the literal `demo-token` so the example stays self-contained. Replace it with real token verification before deployment.

```nim
import std/[asyncdispatch, json, os, times]

import ../src/nimwire

const resource = "https://127.0.0.1:8080/mcp"

proc exampleServer(): McpServer =
  result = newMcpServer("auth-example", "1.0.0")
  result.addTool newMcpTool("whoami", "Show the authenticated caller",
    %*{"type": "object"},
    proc (args: JsonNode, context: McpContext): McpToolResult =
      let caller = if context.principal.isNil: "public"
        else: context.principal.subject
      textResult(caller))

let app = exampleServer()
var config = newMcpHttpConfig(endpoint = "/mcp", host = "127.0.0.1",
  port = Port(8080), allowedHosts = @["127.0.0.1"])
config.authorization = newMcpAuthorizationConfig(
  resource = resource,
  authorizationServers = @["https://auth.example"],
  scopesSupported = @["read"],
  verifier = proc (token, requestedResource: string): McpAuthClaims =
    if token != "demo-token":
      raise newException(ValueError, "invalid demo token")
    newMcpAuthClaims("demo-user", "https://auth.example",
      @[requestedResource], @["read"], epochTime().int64 + 300))

echo "Serving bearer-protected MCP server on http://127.0.0.1:8080/mcp"
waitFor newMcpHttpServer(app, config).serveHttp()
```

The repository example adds a command-line mode switch for `public`, `bearer`, and `scope`. Compile it with:

```sh
nim c -r examples/auth_server.nim bearer
```

See [Security](/guides/security/) for issuer, audience, scope, metadata, and deployment rules.

[View the source example](https://github.com/martineastwood/nimwire/blob/main/examples/auth_server.nim)
