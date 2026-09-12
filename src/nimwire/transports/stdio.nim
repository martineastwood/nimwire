## Newline-delimited JSON-RPC transport over stdin and stdout.

import std/[json, strutils]

import ../core
import ../server

proc serveStdio*(server: McpServer) =
  if server.isNil: raise newMcpError("server must not be nil")
  while not endOfFile(stdin):
    let line = stdin.readLine()
    if line.strip.len == 0: continue
    var request: JsonNode
    try:
      request = parseJson(line)
    except CatchableError:
      stdout.writeLine($errorResponse(newJNull(), -32700, "Parse error"))
      flushFile(stdout)
      continue
    let output = server.handleJson(request)
    if not output.isNil:
      stdout.writeLine($output)
      flushFile(stdout)
