## Lightweight JSON Schema validation for tool boundaries.

import std/[json, strutils, unicode]

import ./core

const schemaTypes = [
  "null", "boolean", "object", "array", "number", "integer", "string"]

const supportedSchemaKeywords = [
  "$schema", "$id", "type", "properties", "required",
  "additionalProperties", "items", "prefixItems", "allOf", "anyOf",
  "oneOf", "not", "enum", "const", "minLength", "maxLength",
  "minItems", "maxItems", "uniqueItems", "minProperties", "maxProperties",
  "minimum", "exclusiveMinimum", "maximum", "exclusiveMaximum",
  "format", "x-mcp-header"]

type
  McpHeaderBinding* = object
    ## A tool argument path mirrored into `Mcp-Param-{name}`.
    name*: string
    path*: seq[string]
    valueType*: string

proc validateJsonSchema*(schema: JsonNode, context = "JSON Schema")
proc requireJsonSchema*(schema: JsonNode, context = "JSON Schema"): JsonNode

proc schemaFailure(path, message: string): ref McpError =
  newMcpError(path & ": " & message)

proc isHttpTokenCharacter(character: char): bool =
  (character >= 'a' and character <= 'z') or
    (character >= 'A' and character <= 'Z') or
    (character >= '0' and character <= '9') or
    character in {'!', '#', '$', '%', '&', '\'', '*', '+', '-', '.', '^',
                  '_', '`', '|', '~'}

proc validateMcpHeaderName(name, path: string) =
  if name.len == 0:
    raise schemaFailure(path, "x-mcp-header must not be empty")
  for character in name:
    if not isHttpTokenCharacter(character):
      raise schemaFailure(path, "x-mcp-header must be an HTTP token")

proc collectMcpHeaderBindings(node: JsonNode, path: seq[string],
                              reachable, atRoot: bool,
                              bindings: var seq[McpHeaderBinding]) =
  if node.isNil or node.kind != JObject: return
  if "x-mcp-header" in node:
    if not reachable or node["x-mcp-header"].kind != JString:
      raise schemaFailure("tool inputSchema", "x-mcp-header is only valid on statically reachable properties")
    if "$ref" in node:
      raise schemaFailure("tool inputSchema", "x-mcp-header cannot be combined with $ref")
    let name = node["x-mcp-header"].getStr
    validateMcpHeaderName(name, "tool inputSchema")
    if "type" notin node or node["type"].kind != JString or
        node["type"].getStr notin ["string", "integer", "boolean"]:
      raise schemaFailure("tool inputSchema", "x-mcp-header requires a string, integer, or boolean property")
    for binding in bindings:
      if binding.name.toLowerAscii == name.toLowerAscii:
        raise schemaFailure("tool inputSchema", "x-mcp-header values must be unique")
    bindings.add McpHeaderBinding(name: name, path: path,
      valueType: node["type"].getStr)

  if "properties" in node and node["properties"].kind == JObject:
    for name, property in node["properties"].pairs:
      var propertyPath = path
      propertyPath.add name
      collectMcpHeaderBindings(property, propertyPath,
        reachable or atRoot, false, bindings)

  for key in ["additionalProperties", "items", "prefixItems", "allOf",
              "anyOf", "oneOf", "not"]:
    if key notin node: continue
    let nested = node[key]
    collectMcpHeaderBindings(nested, path, false, false, bindings)
    if key in ["prefixItems", "allOf", "anyOf", "oneOf"] and
        nested.kind == JArray:
      for property in nested.items:
        collectMcpHeaderBindings(property, path, false, false, bindings)

proc mcpHeaderBindings*(schema: JsonNode): seq[McpHeaderBinding] =
  ## Return the valid statically reachable `x-mcp-header` annotations.
  discard requireJsonSchema(schema, "tool inputSchema")
  collectMcpHeaderBindings(schema, @[], false, true, result)

proc schemaObject(node: JsonNode, path: string): JsonNode =
  if node.isNil or node.kind != JObject:
    raise schemaFailure(path, "schema must be an object")
  node

proc requireJsonSchema*(schema: JsonNode, context = "JSON Schema"): JsonNode =
  result = schemaObject(schema, context)
  validateJsonSchema(result, context)

proc validateStringKeyword(schema: JsonNode, key, path: string) =
  if key in schema:
    if schema[key].kind != JInt or schema[key].getInt < 0:
      raise schemaFailure(path, key & " must be a non-negative integer")

proc validateNumberKeyword(schema: JsonNode, key, path: string) =
  if key in schema and schema[key].kind notin {JInt, JFloat}:
    raise schemaFailure(path, key & " must be a number")

proc validateUniqueStrings(node: JsonNode, path: string) =
  if node.kind != JArray:
    raise schemaFailure(path, "must be an array")
  var seen: seq[string]
  for value in node.items:
    if value.kind != JString:
      raise schemaFailure(path, "must contain only strings")
    if value.getStr in seen:
      raise schemaFailure(path, "must not contain duplicate strings")
    seen.add value.getStr

proc validateSchemaNode(node: JsonNode, path: string)

proc validateSchemaArray(node: JsonNode, key, path: string) =
  if key notin node: return
  if node[key].kind != JArray or node[key].len == 0:
    raise schemaFailure(path, key & " must be a non-empty array")
  for index, value in node[key].pairs:
    validateSchemaNode(value, path & "." & key & "[" & $index & "]")

proc validateSchemaNode(node: JsonNode, path: string) =
  if node.kind == JBool: return
  let schema = schemaObject(node, path)
  for key in schema.keys:
    if key notin supportedSchemaKeywords:
      raise schemaFailure(path, "unsupported schema keyword: " & key)
  if "$schema" in schema and schema["$schema"].kind != JString:
    raise schemaFailure(path, "$schema must be a string")
  if "$id" in schema and schema["$id"].kind != JString:
    raise schemaFailure(path, "$id must be a string")
  if "format" in schema and schema["format"].kind != JString:
    raise schemaFailure(path, "format must be a string")
  if "type" in schema:
    let value = schema["type"]
    if value.kind == JString:
      if value.getStr notin schemaTypes:
        raise schemaFailure(path, "type is not a supported JSON type")
    elif value.kind == JArray:
      if value.len == 0: raise schemaFailure(path, "type must not be empty")
      validateUniqueStrings(value, path & ".type")
      for item in value.items:
        if item.getStr notin schemaTypes:
          raise schemaFailure(path, "type contains an unsupported JSON type")
    else:
      raise schemaFailure(path, "type must be a string or array of strings")
  if "properties" in schema:
    if schema["properties"].kind != JObject:
      raise schemaFailure(path, "properties must be an object")
    for key, value in schema["properties"].pairs:
      validateSchemaNode(value, path & ".properties[" & key & "]")
  if "required" in schema:
    validateUniqueStrings(schema["required"], path & ".required")
  if "additionalProperties" in schema and
      schema["additionalProperties"].kind notin {JBool, JObject}:
    raise schemaFailure(path, "additionalProperties must be a schema or boolean")
  if "items" in schema and schema["items"].kind notin {JBool, JObject}:
    raise schemaFailure(path, "items must be a schema or boolean")
  if "prefixItems" in schema:
    if schema["prefixItems"].kind != JArray:
      raise schemaFailure(path, "prefixItems must be an array")
    for index, value in schema["prefixItems"].pairs:
      validateSchemaNode(value, path & ".prefixItems[" & $index & "]")
  for key in ["allOf", "anyOf", "oneOf"]:
    validateSchemaArray(schema, key, path)
  for key in ["not"]:
    if key in schema:
      validateSchemaNode(schema[key], path & "." & key)
  if "enum" in schema and
      (schema["enum"].kind != JArray or schema["enum"].len == 0):
    raise schemaFailure(path, "enum must be a non-empty array")
  if "const" in schema and schema["const"].isNil:
    raise schemaFailure(path, "const must contain a JSON value")
  for key in ["minLength", "maxLength", "minItems", "maxItems",
              "minProperties", "maxProperties"]:
    validateStringKeyword(schema, key, path)
  for key in ["maximum", "exclusiveMaximum", "minimum", "exclusiveMinimum"]:
    validateNumberKeyword(schema, key, path)
  if "uniqueItems" in schema and schema["uniqueItems"].kind != JBool:
    raise schemaFailure(path, "uniqueItems must be a boolean")

proc validateJsonSchema*(schema: JsonNode, context = "JSON Schema") =
  validateSchemaNode(schema, context)

proc validateToolName*(name: string) =
  if name.len < 1 or name.len > 128:
    raise newMcpError("tool name must contain 1 to 128 characters")
  for character in name:
    if not ((character >= 'a' and character <= 'z') or
            (character >= 'A' and character <= 'Z') or
            (character >= '0' and character <= '9') or
            character in {'_', '-', '.'}):
      raise newMcpError("tool name contains an unsupported character: " &
        $character)

proc validateToolPresentation*(icons, annotations: JsonNode) =
  if not icons.isNil:
    if icons.kind != JArray:
      raise newMcpError("tool icons must be an array")
    for icon in icons.items:
      if icon.kind != JObject:
        raise newMcpError("tool icons must contain objects")
      if "src" notin icon or icon["src"].kind != JString or
          icon["src"].getStr.len == 0:
        raise newMcpError("tool icon requires a non-empty src")
      if "mimeType" in icon and icon["mimeType"].kind != JString:
        raise newMcpError("tool icon mimeType must be a string")
      if "sizes" in icon:
        validateUniqueStrings(icon["sizes"], "tool icon sizes")
      if "theme" in icon and icon["theme"].kind != JString:
        raise newMcpError("tool icon theme must be a string")
  if not annotations.isNil and annotations.kind != JObject:
    raise newMcpError("tool annotations must be an object")

proc jsonType(node: JsonNode): string =
  case node.kind
  of JNull: "null"
  of JBool: "boolean"
  of JObject: "object"
  of JArray: "array"
  of JInt: "integer"
  of JFloat: "number"
  of JString: "string"

proc valueFailure(path, message: string): ref McpError =
  newMcpError(path & ": " & message)

proc matchesType(value: JsonNode, expected: string): bool =
  case expected
  of "number": value.kind in {JInt, JFloat}
  of "integer": value.kind == JInt
  else: jsonType(value) == expected

proc matchesAnyType(value, typeNode: JsonNode): bool =
  if typeNode.kind == JString:
    return matchesType(value, typeNode.getStr)
  for expected in typeNode.items:
    if matchesType(value, expected.getStr): return true
  false

proc jsonNumber(value: JsonNode): float =
  if value.kind == JInt: value.getInt.float else: value.getFloat

proc jsonEqual(left, right: JsonNode): bool =
  if left.isNil or right.isNil: return left.isNil and right.isNil
  if left.kind != right.kind and not (
      left.kind in {JInt, JFloat} and right.kind in {JInt, JFloat}):
    return false
  if left.kind in {JInt, JFloat} and right.kind in {JInt, JFloat}:
    return left.getFloat == right.getFloat
  if left.kind == JObject:
    if left.len != right.len: return false
    for key, value in left.pairs:
      if key notin right or not jsonEqual(value, right[key]): return false
    return true
  if left.kind == JArray:
    if left.len != right.len: return false
    for index in 0 ..< left.len:
      if not jsonEqual(left[index], right[index]): return false
    return true
  left == right

proc validateJsonValueNode(schema, value: JsonNode, path: string)

proc validateCombinator(schema: JsonNode, key: string, value: JsonNode,
                        path: string) =
  if key notin schema: return
  let alternatives = schema[key]
  var matches = 0
  for option in alternatives.items:
    try:
      validateJsonValueNode(option, value, path)
      inc matches
    except McpError:
      discard
  if key == "allOf" and matches != alternatives.len:
    raise valueFailure(path, "does not match allOf")
  if key == "anyOf" and matches == 0:
    raise valueFailure(path, "does not match anyOf")
  if key == "oneOf" and matches != 1:
    raise valueFailure(path, "does not match exactly one oneOf schema")

proc validateObjectValue(schema, value: JsonNode, path: string) =
  if value.kind != JObject: return
  if "required" in schema:
    for field in schema["required"].items:
      if field.getStr notin value:
        raise valueFailure(path, "missing required property '" & field.getStr & "'")
  let properties = if "properties" in schema: schema["properties"] else: newJObject()
  for key, property in properties.pairs:
    if key in value:
      validateJsonValueNode(property, value[key], path & "." & key)
  if "additionalProperties" in schema and
      schema["additionalProperties"].kind == JBool and
      not schema["additionalProperties"].getBool:
    for key in value.keys:
      if key notin properties:
        raise valueFailure(path, "unexpected property '" & key & "'")
  elif "additionalProperties" in schema and
      schema["additionalProperties"].kind == JObject:
    for key, property in value.pairs:
      if key notin properties:
        validateJsonValueNode(schema["additionalProperties"], property,
          path & "." & key)
  if "minProperties" in schema and value.len < schema["minProperties"].getInt:
    raise valueFailure(path, "has fewer than minProperties")
  if "maxProperties" in schema and value.len > schema["maxProperties"].getInt:
    raise valueFailure(path, "has more than maxProperties")

proc validateArrayValue(schema, value: JsonNode, path: string) =
  if value.kind != JArray: return
  if "minItems" in schema and value.len < schema["minItems"].getInt:
    raise valueFailure(path, "has fewer than minItems")
  if "maxItems" in schema and value.len > schema["maxItems"].getInt:
    raise valueFailure(path, "has more than maxItems")
  if "uniqueItems" in schema and schema["uniqueItems"].getBool:
    for i in 0 ..< value.len:
      for j in i + 1 ..< value.len:
        if jsonEqual(value[i], value[j]):
          raise valueFailure(path, "contains duplicate items")
  if "items" in schema:
    for index in 0 ..< value.len:
      validateJsonValueNode(schema["items"], value[index],
        path & "[" & $index & "]")
  if "prefixItems" in schema:
    for index in 0 ..< value.len:
      if index < schema["prefixItems"].len:
        validateJsonValueNode(schema["prefixItems"][index], value[index],
          path & "[" & $index & "]")

proc validateJsonValueNode(schema, value: JsonNode, path: string) =
  if schema.kind == JBool:
    if not schema.getBool:
      raise valueFailure(path, "is rejected by the schema")
    return
  if schema.isNil or schema.kind != JObject:
    raise valueFailure(path, "schema must be an object or boolean")
  if "type" in schema and not matchesAnyType(value, schema["type"]):
    raise valueFailure(path, "expected " & $schema["type"] & ", got " &
      jsonType(value))
  if "enum" in schema:
    var matches = false
    for option in schema["enum"].items:
      if jsonEqual(value, option): matches = true
    if not matches: raise valueFailure(path, "is not one of enum values")
  if "const" in schema and not jsonEqual(value, schema["const"]):
    raise valueFailure(path, "does not match const")
  validateCombinator(schema, "allOf", value, path)
  validateCombinator(schema, "anyOf", value, path)
  validateCombinator(schema, "oneOf", value, path)
  if "not" in schema:
    var matchesForbidden = false
    try:
      validateJsonValueNode(schema["not"], value, path)
    except McpError:
      matchesForbidden = true
    if not matchesForbidden:
      raise valueFailure(path, "matches a forbidden schema")
  if value.kind == JString:
    if "minLength" in schema and value.getStr.runeLen < schema["minLength"].getInt:
      raise valueFailure(path, "has fewer than minLength characters")
    if "maxLength" in schema and value.getStr.runeLen > schema["maxLength"].getInt:
      raise valueFailure(path, "has more than maxLength characters")
  if value.kind in {JInt, JFloat}:
    let number = jsonNumber(value)
    if "minimum" in schema and number < schema["minimum"].getFloat:
      raise valueFailure(path, "is less than minimum")
    if "exclusiveMinimum" in schema and number <= schema["exclusiveMinimum"].getFloat:
      raise valueFailure(path, "is not greater than exclusiveMinimum")
    if "maximum" in schema and number > schema["maximum"].getFloat:
      raise valueFailure(path, "is greater than maximum")
    if "exclusiveMaximum" in schema and number >= schema["exclusiveMaximum"].getFloat:
      raise valueFailure(path, "is not less than exclusiveMaximum")
  validateObjectValue(schema, value, path)
  validateArrayValue(schema, value, path)

proc validateJsonValue*(schema, value: JsonNode, context = "value") =
  discard requireJsonSchema(schema, "tool schema")
  validateJsonValueNode(schema, value, context)
