## Run with: nim c -r examples/auth_server.nim [public|bearer|scope]

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

let mode = if paramCount() == 0: "public" else: paramStr(1)
let app = exampleServer()
var config = newMcpHttpConfig(endpoint = "/mcp", host = "127.0.0.1",
  port = Port(8080), allowedHosts = @["127.0.0.1"])
case mode
of "public": discard
of "bearer", "scope":
  let requiredScopes = if mode == "scope": @["read"] else: @[]
  config.authorization = newMcpAuthorizationConfig(
    resource = resource,
    authorizationServers = @["https://auth.example"],
    scopesSupported = @["read"], requiredScopes = requiredScopes,
    verifier = proc (token, requestedResource: string): McpAuthClaims =
      if token != "demo-token":
        raise newException(ValueError, "invalid demo token")
      newMcpAuthClaims("demo-user", "https://auth.example",
        @[requestedResource], @["read"], epochTime().int64 + 300))
else:
  raise newException(ValueError, "mode must be public, bearer, or scope")

echo "Serving " & mode & " MCP server on http://127.0.0.1:8080/mcp"
waitFor newMcpHttpServer(app, config).serveHttp()
