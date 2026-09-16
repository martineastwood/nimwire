import nimwire

type EchoInput = object
  text*: string

let server = mcpServer("nimwire-echo", "0.1.0"):
  server.tool "echo", "Echo text back to the caller",
    proc (input: EchoInput): string =
      input.text

server.serveStdio()
