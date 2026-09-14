## In-process linked transport for tests and local composition.

import std/[asyncdispatch, options]

import ../context
import ../core
import ../server
import ../transport

type
  McpInProcessState = ref object
    server: McpServer
    closed: bool

proc dispatchRequest(state: McpInProcessState,
                     message: McpJsonRpcMessage):
                     Future[McpJsonRpcMessage] {.async.} =
  if state.closed: raise newMcpError("MCP in-process transport is closed")
  if message.kind != mcpRequestMessage:
    raise newMcpError("MCP in-process transport requests require a request")
  let context = newMcpContext(message.request,
    McpTransportInfo(kind: mcpTransportInProcess, name: "in-process"))
  let response = await state.server.handleMessageAsync(message, context)
  if not response.isSome:
    raise newMcpError("MCP request did not produce a response")
  response.get

proc dispatchNotification(state: McpInProcessState,
                          message: McpJsonRpcMessage): Future[void] {.async.} =
  if state.closed: raise newMcpError("MCP in-process transport is closed")
  if message.kind != mcpNotificationMessage:
    raise newMcpError("MCP in-process notifications require a notification")
  let context = newMcpContext(message.request,
    McpTransportInfo(kind: mcpTransportInProcess, name: "in-process"))
  discard await state.server.handleMessageAsync(message, context)

proc newMcpInProcessTransport*(server: McpServer): McpMessageTransport =
  if server.isNil: raise newMcpError("MCP in-process server must not be nil")
  let state = McpInProcessState(server: server)
  let request: McpTransportRequest = proc (message: McpJsonRpcMessage):
      Future[McpJsonRpcMessage] {.async.} = await state.dispatchRequest(message)
  let notification: McpTransportNotification = proc (message: McpJsonRpcMessage):
      Future[void] {.async.} = await state.dispatchNotification(message)
  newMcpMessageTransport(request, notification, proc () = state.closed = true)

proc newMcpInProcessPeer*(server: McpServer,
                          metadata = McpRequestMeta()): McpPeer =
  newMcpPeer(newMcpInProcessTransport(server), metadata)
