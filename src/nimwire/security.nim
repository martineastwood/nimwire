## Small, opt-in security controls shared by transports and handlers.

import std/[json, strutils, uri]

import ./core

type
  McpSecurityLimits* = object
    ## Zero means unlimited for that limit.
    maxLineBytes*: int
    maxToolCount*: int
    maxContentBytes*: int
    maxConcurrentCalls*: int

proc validateSecurityLimits*(limits: McpSecurityLimits)

proc newMcpSecurityLimits*(maxLineBytes = 0, maxToolCount = 0,
                           maxContentBytes = 0, maxConcurrentCalls = 0): McpSecurityLimits =
  result = McpSecurityLimits(maxLineBytes: maxLineBytes, maxToolCount: maxToolCount,
    maxContentBytes: maxContentBytes, maxConcurrentCalls: maxConcurrentCalls)
  validateSecurityLimits(result)

proc validateSecurityLimits*(limits: McpSecurityLimits) =
  if limits.maxLineBytes < 0 or limits.maxToolCount < 0 or
      limits.maxContentBytes < 0 or limits.maxConcurrentCalls < 0:
    raise newMcpError("security limits must be non-negative")

proc validateJsonSize*(value: JsonNode, maxBytes: int, label = "JSON value") =
  if maxBytes > 0 and (if value.isNil: 0 else: ($value).len) > maxBytes:
    raise newMcpError(label & " exceeds the configured size limit",
      mcpInvalidParamsCode)

proc sensitiveKey(key: string, extra: openArray[string]): bool =
  let normalized = key.toLowerAscii
  if normalized in ["authorization", "proxy-authorization", "cookie",
                    "set-cookie", "password", "passwd", "secret",
                    "token", "access_token", "refresh_token", "api_key",
                    "apikey"]:
    return true
  for candidate in extra:
    if normalized == candidate.toLowerAscii: return true

proc redactJson*(value: JsonNode, sensitiveKeys: seq[string] = @[]): JsonNode =
  if value.isNil: return nil
  case value.kind
  of JObject:
    result = newJObject()
    for key, item in value.pairs:
      result[key] = if sensitiveKey(key, sensitiveKeys): %"[REDACTED]"
        else: redactJson(item, sensitiveKeys)
  of JArray:
    result = newJArray()
    for item in value.items: result.add redactJson(item, sensitiveKeys)
  else:
    result = value

proc redactHeaderValue*(name, value: string): string =
  if sensitiveKey(name, @[]): return "[REDACTED]"
  value

proc redactBearerToken*(value: string): string =
  let parts = value.strip.splitWhitespace()
  if parts.len == 2 and parts[0].toLowerAscii == "bearer":
    return parts[0] & " [REDACTED]"
  value

proc isSafeMcpUrl*(value: string, allowHttp = false): bool =
  if value.len == 0: return false
  for character in value:
    if character in {' ', '\t', '\r', '\n', '\x00'}: return false
  try:
    let parsed = parseUri(value)
    if parsed.opaque or parsed.hostname.len == 0 or
        parsed.username.len > 0 or parsed.password.len > 0:
      return false
    parsed.scheme.toLowerAscii == "https" or
      (allowHttp and parsed.scheme.toLowerAscii == "http")
  except CatchableError:
    false

proc requireSafeMcpUrl*(value: string, allowHttp = false): string =
  if not isSafeMcpUrl(value, allowHttp):
    raise newMcpError("URL must be an absolute HTTPS URL without credentials")
  value
