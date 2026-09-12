## Resource examples: files, generated data, database schemas, and web URLs.

import std/[asyncdispatch, json, os]

import ../src/nimwire

let projectRoot = getCurrentDir()

let server = mcpServer("resource-example", "1.0.0"):
  server.addResource newFileResource(projectRoot, "README.md",
    name = "README.md", uriValue = "file:///project/README.md",
    mimeType = "text/markdown")

  let generated: McpResourceReadHandler = proc (uri: string,
      context: McpContext): Future[seq[McpResourceContent]] {.async.} =
    discard context
    let generatedData = %*{
      "generated": true,
      "items": ["one", "two", "three"]
    }
    @[
      resourceText(uri, $generatedData, "application/json")]
  server.addResource newMcpResource("data://generated", "Generated data",
    generated, mimeType = "application/json")

  let databaseSchema = %*{
    "tables": {
      "users": {"columns": ["id", "email"]}
    }
  }
  server.addResource newMcpResource("db://main/schema", "Database schema",
    resourceText("db://main/schema", $databaseSchema, "application/json"),
    mimeType = "application/json")

  server.addResource newMcpResource("https://example.com/data.json",
    "Public web data", @[], mimeType = "application/json")

server.serveStdio()
