## Lightweight stdin fuzz harness.
## Feed arbitrary newline-delimited JSON values to exercise parser boundaries:
##   cat corpus.txt | nim c -r tests/fuzz_parser.nim

import std/[asyncdispatch, json]

import ../src/nimwire

let server = newMcpServer("fuzz", "1.0.0")
let headers = @[
  header("Content-Type", "application/json"),
  header("Accept", "application/json, text/event-stream"),
  header("MCP-Protocol-Version", mcpProtocolVersion),
  header("Mcp-Method", "tools/list")]

for line in stdin.lines:
  if line.len == 0: continue
  try:
    discard parseMcpMessage(line)
  except CatchableError:
    discard
  try:
    let value = parseJson(line)
    discard server.handleJson(value)
    discard redactJson(value)
    if value.kind == JObject:
      try:
        discard parseClientIdMetadata(value)
      except CatchableError:
        discard
  except CatchableError:
    discard
  try:
    discard isSafeMcpUrl(line)
    discard extractBearerToken(line)
    discard waitFor server.handleHttpRequest(
      newMcpHttpRequest("POST", "/mcp", line, headers))
  except CatchableError:
    discard
