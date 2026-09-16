---
title: Security
description: Protect HTTP servers, bound resource access, and keep sensitive data out of logs.
---

Read the repository's [security checklist](https://github.com/martineastwood/nimwire/blob/main/SECURITY.md) before exposing a server publicly. nimwire gives you opt-in controls, but your verifier, deployment, and application policy still decide who can do what.

## Protect Streamable HTTP with bearer authorization

Authorization is disabled by default. Enable it on the HTTP config with an HTTPS resource URL, one or more HTTPS authorization servers, and a verifier:

```nim
import std/[asyncdispatch, json, nativesockets, os, times]
import nimwire

let server = newMcpServer("secure", "1.0.0")
var config = newMcpHttpConfig(endpoint = "/mcp", host = "127.0.0.1",
  port = Port(8080), allowedHosts = @["127.0.0.1"])
config.authorization = newMcpAuthorizationConfig(
  resource = "https://example.com/mcp",
  authorizationServers = @["https://auth.example"],
  scopesSupported = @["read"],
  requiredScopes = @["read"],
  verifier = proc (token, resource: string): McpAuthClaims =
    if token != getEnv("DEMO_TOKEN"):
      raise newException(ValueError, "invalid token")
    newMcpAuthClaims("demo-user", "https://auth.example",
      @[resource], @["read"], epochTime().int64 + 300))

let http = newMcpHttpServer(server, config)
waitFor http.serveHttp()
```

The verifier is where your application validates the bearer token. nimwire then checks expiry, issuer, audience, and required scopes before creating `context.principal`.

Missing or invalid credentials produce `401`. A valid token without a required scope produces `403`. Protected-resource metadata is available from `/.well-known/oauth-protected-resource/<endpoint>` when authorization is enabled.

For a custom policy, supply `middleware` instead of `verifier`. An allowed decision must include a principal.

## Filter features by principal

Authorization and visibility are separate decisions. Use filters to decide which already-registered features a principal can discover and call:

```nim
server.setToolFilter(proc (name: string, principal: McpPrincipal): bool =
  not principal.isNil and
    ("admin" notin name or "admin" in principal.scopes))
```

The same pattern is available for resources and prompts. Do not use caller-facing `annotations` as an authorization policy.

## Keep file resources inside a root

Use `newFileResource` or `newFileResourceTemplate` instead of joining caller input to a path yourself. `safeResourcePath` rejects traversal and symlink escapes before reading a file. Use a narrow root directory and a URI that does not reveal more filesystem detail than necessary.

## Set bounded limits

```nim
server.setSecurityLimits(newMcpSecurityLimits(
  maxLineBytes = 1024 * 1024,
  maxToolCount = 100,
  maxContentBytes = 4 * 1024 * 1024,
  maxConcurrentCalls = 32))
```

Zero means unlimited for an individual limit. HTTP requests have their own `maxBodyBytes`, `maxNestingDepth`, and `maxConcurrentRequests` settings. Set explicit values for public endpoints.

## Redact secrets

Use the reusable helpers before logging data that may contain credentials:

```nim
let safe = redactJson(payload)
let header = redactHeaderValue("Authorization", authorizationValue)
let token = redactBearerToken(authorizationValue)
```

The default sensitive-key list includes authorization headers, cookies, passwords, secrets, tokens, and API keys. Pass extra key names to `redactJson` for application-specific fields.

`requireSafeMcpUrl` accepts absolute HTTPS URLs without embedded credentials. HTTP is accepted only when you explicitly pass `allowHttp = true`, which is appropriate for controlled local development only.

Related: [Transports](/guides/transports/) and [Production controls](/guides/production/).
