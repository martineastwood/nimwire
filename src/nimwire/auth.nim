## HTTP authorization hooks with safe bearer-token defaults.

import std/[json, strutils, times]

import ./context
import ./core
import ./security

type
  McpAuthHeader* = object
    name*: string
    value*: string

  McpAuthorizationRequest* = object
    methodName*: string
    path*: string
    resource*: string
    headers*: seq[McpAuthHeader]

  McpAuthClaims* = object
    subject*: string
    issuer*: string
    audience*: seq[string]
    scopes*: seq[string]
    expiresAt*: int64
    claims*: JsonNode

  McpBearerTokenVerifier* = proc (token, resource: string): McpAuthClaims {.closure.}
  McpAuthorizationMiddleware* = proc (
      request: McpAuthorizationRequest): McpAuthorizationResult {.closure.}

  McpAuthorizationResult* = object
    allowed*: bool
    principal*: McpPrincipal
    status*: int
    message*: string
    scopes*: seq[string]

  McpProtectedResourceMetadata* = object
    resource*: string
    authorizationServers*: seq[string]
    scopesSupported*: seq[string]

  McpAuthorizationConfig* = object
    enabled*: bool
    resource*: string
    authorizationServers*: seq[string]
    scopesSupported*: seq[string]
    requiredScopes*: seq[string]
    resourceMetadataUrl*: string
    verifier*: McpBearerTokenVerifier
    middleware*: McpAuthorizationMiddleware

  McpClientIdMetadata* = object
    clientId*: string
    clientName*: string
    redirectUris*: seq[string]
    extraFields*: JsonNode

proc newMcpAuthClaims*(subject, issuer: string,
                       audience, scopes: seq[string], expiresAt: int64,
                       claims: JsonNode = nil): McpAuthClaims =
  if subject.len == 0 or issuer.len == 0:
    raise newMcpError("authorization claims require subject and issuer")
  if audience.len == 0:
    raise newMcpError("authorization claims require an audience")
  McpAuthClaims(subject: subject, issuer: issuer, audience: audience,
    scopes: scopes, expiresAt: expiresAt,
    claims: if claims.isNil: newJObject() else: claims)

proc newMcpAuthorizationConfig*(resource = "",
                                authorizationServers: seq[string] = @[],
                                scopesSupported: seq[string] = @[],
                                requiredScopes: seq[string] = @[],
                                resourceMetadataUrl = "",
                                verifier: McpBearerTokenVerifier = nil,
                                middleware: McpAuthorizationMiddleware = nil,
                                enabled = false): McpAuthorizationConfig =
  let active = enabled or not verifier.isNil or not middleware.isNil
  if active and (resource.len == 0 or authorizationServers.len == 0):
    raise newMcpError("enabled authorization requires a resource and issuer")
  if active and not isSafeMcpUrl(resource):
    raise newMcpError("authorization resource must be an absolute HTTPS URL")
  for issuer in authorizationServers:
    if not isSafeMcpUrl(issuer):
      raise newMcpError("authorization issuer must be an absolute HTTPS URL")
  if resourceMetadataUrl.len > 0 and not isSafeMcpUrl(resourceMetadataUrl):
    raise newMcpError("resource metadata URL must be an absolute HTTPS URL")
  McpAuthorizationConfig(enabled: active, resource: resource,
    authorizationServers: authorizationServers, scopesSupported: scopesSupported,
    requiredScopes: requiredScopes, resourceMetadataUrl: resourceMetadataUrl,
    verifier: verifier, middleware: middleware)

proc newMcpAuthorizationRequest*(methodName, path, resource: string,
                                 headers: seq[McpAuthHeader] = @[]):
                                 McpAuthorizationRequest =
  McpAuthorizationRequest(methodName: methodName, path: path,
    resource: resource, headers: headers)

proc extractBearerToken*(authorization: string): string =
  let parts = authorization.strip.splitWhitespace()
  if parts.len != 2 or parts[0].toLowerAscii != "bearer" or parts[1].len == 0:
    return ""
  parts[1]

proc headerValue(headers: openArray[McpAuthHeader], name: string): string =
  var found = false
  for header in headers:
    if header.name.toLowerAscii == name.toLowerAscii:
      if found: return ""
      found = true
      result = header.value

proc hasValue(values: openArray[string], expected: string): bool =
  for value in values:
    if value == expected: return true
  false

proc missingScope(required, granted: seq[string]): bool =
  for scope in required:
    if not hasValue(granted, scope): return true
  false

proc authorizationFailure(status: int, message: string): McpAuthorizationResult =
  McpAuthorizationResult(allowed: false, status: status, message: message)

proc authorize*(config: McpAuthorizationConfig,
                request: McpAuthorizationRequest): McpAuthorizationResult =
  if not config.enabled:
    return McpAuthorizationResult(allowed: true)
  if not config.middleware.isNil:
    result = config.middleware(request)
    if result.allowed and result.principal.isNil:
      return authorizationFailure(500, "authorization middleware returned no principal")
    if result.status == 0:
      result.status = if result.allowed: 200 else: 401
    return
  let authorization = request.headers.headerValue("Authorization")
  let token = extractBearerToken(authorization)
  if token.len == 0:
    return authorizationFailure(401, "authorization required")
  if config.verifier.isNil:
    return authorizationFailure(401, "bearer token verification is not configured")
  var claims: McpAuthClaims
  try:
    claims = config.verifier(token, config.resource)
  except CatchableError:
    return authorizationFailure(401, "invalid bearer token")
  let now = epochTime().int64
  if claims.subject.len == 0 or claims.issuer.len == 0 or claims.expiresAt <= now:
    return authorizationFailure(401, "invalid or expired bearer token")
  if config.authorizationServers.len > 0 and
      claims.issuer notin config.authorizationServers:
    return authorizationFailure(401, "token issuer is not authorized")
  if config.resource.len == 0 or not hasValue(claims.audience, config.resource):
    return authorizationFailure(401, "token audience does not match this resource")
  if missingScope(config.requiredScopes, claims.scopes):
    return McpAuthorizationResult(allowed: false, status: 403,
      message: "insufficient scope", scopes: config.requiredScopes)
  result.allowed = true
  result.status = 200
  result.scopes = claims.scopes
  result.principal = newMcpPrincipal(claims.subject, claims.claims,
    claims.issuer, claims.scopes)

proc protectedResourceMetadata*(config: McpAuthorizationConfig):
    McpProtectedResourceMetadata =
  if config.resource.len == 0 or config.authorizationServers.len == 0:
    raise newMcpError("protected resource metadata requires a resource and issuer")
  McpProtectedResourceMetadata(resource: config.resource,
    authorizationServers: config.authorizationServers,
    scopesSupported: config.scopesSupported)

proc toJson*(metadata: McpProtectedResourceMetadata): JsonNode =
  result = %*{
    "resource": metadata.resource,
    "authorization_servers": metadata.authorizationServers
  }
  if metadata.scopesSupported.len > 0:
    result["scopes_supported"] = %metadata.scopesSupported

proc authorizationChallenge*(config: McpAuthorizationConfig,
                             error = "", scope = ""): string =
  result = "Bearer"
  if config.resourceMetadataUrl.len > 0:
    result &= " resource_metadata=\"" & config.resourceMetadataUrl & "\""
  if error.len > 0:
    result &= " error=\"" & error & "\""
  if scope.len > 0:
    result &= " scope=\"" & scope & "\""

proc parseClientIdMetadata*(node: JsonNode): McpClientIdMetadata =
  let value = requireObject(node, "client ID metadata")
  result.clientId = requiredString(value, "client_id", "client ID metadata")
  if not isSafeMcpUrl(result.clientId):
    raise newMcpError("client ID metadata client_id must be an absolute URL")
  result.clientName = if "client_name" in value:
    requiredString(value, "client_name", "client ID metadata") else: ""
  if "redirect_uris" in value:
    if value["redirect_uris"].kind != JArray:
      raise newMcpError("client ID metadata redirect_uris must be an array")
    for uriValue in value["redirect_uris"].items:
      if uriValue.kind != JString or not isSafeMcpUrl(uriValue.getStr):
        raise newMcpError("client ID metadata redirect URIs must be absolute URLs")
      result.redirectUris.add uriValue.getStr
  result.extraFields = newJObject()
  for key, item in value.pairs:
    if key notin ["client_id", "client_name", "redirect_uris"]:
      result.extraFields[key] = item

proc rejectTokenPassthrough*(authorization: string) =
  if extractBearerToken(authorization).len > 0:
    raise newMcpError("MCP bearer tokens must not be passed to downstream services")
