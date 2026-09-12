## Small schema helpers used at registration boundaries.

import std/json

import ./core

proc requireJsonSchema*(schema: JsonNode, context: string): JsonNode =
  if schema.isNil or schema.kind != JObject:
    raise newMcpError(context & " must be a JSON object")
  schema
