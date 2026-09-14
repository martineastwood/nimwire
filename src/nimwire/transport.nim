## Transport-neutral MCP messages and request/response handling.

import std/[asyncdispatch, json]

import ./core

type
  McpTransportRequest* = proc (message: McpJsonRpcMessage):
      Future[McpJsonRpcMessage] {.closure.}
  McpTransportNotification* = proc (message: McpJsonRpcMessage):
      Future[void] {.closure.}
  McpTransportClose* = proc () {.closure.}

  McpMessageTransport* = ref object
    ## A message transport carries already validated JSON-RPC values. It does
    ## not know about servers, HTTP, stdio, or any higher-level client API.
    requestHandler: McpTransportRequest
    notificationHandler: McpTransportNotification
    closeHandler: McpTransportClose
    closed: bool

  McpPeer* = ref object
    ## Small client-side request/response helper shared by proxies and clients.
    transport*: McpMessageTransport
    metadata*: McpRequestMeta
    nextId: int64

proc newMcpRequestMeta*(clientName = "nimwire", clientVersion = "0.1.0",
                        clientCapabilities: JsonNode = nil): McpRequestMeta =
  if clientName.len == 0 or clientVersion.len == 0:
    raise newMcpError("MCP client name and version must not be empty")
  if not clientCapabilities.isNil and clientCapabilities.kind != JObject:
    raise newMcpError("MCP client capabilities must be an object")
  McpRequestMeta(protocolVersion: mcpProtocolVersion, hasClientInfo: true,
    clientInfo: McpClientInfo(name: clientName, version: clientVersion,
      extraFields: newJObject()),
    clientCapabilities: McpClientCapabilities(fields: if clientCapabilities.isNil:
      newJObject() else: clientCapabilities), extensionMetadata: newJObject())

proc newMcpParams*(values: JsonNode = nil,
                   metadata = McpRequestMeta()): McpParams =
  if not values.isNil and values.kind != JObject:
    raise newMcpError("MCP request params must be an object")
  let meta = if metadata.protocolVersion.len == 0: newMcpRequestMeta() else:
    metadata
  McpParams(values: if values.isNil: newJObject() else: values, meta: meta)

proc newMcpRequest*(id: McpId, methodName: string, values: JsonNode = nil,
                   metadata = McpRequestMeta()): McpRpcRequest =
  validateMethod(methodName)
  McpRpcRequest(kind: mcpRequest, id: id, methodName: methodName,
    params: newMcpParams(values, metadata), extraFields: newJObject())

proc newMcpNotification*(methodName: string, values: JsonNode = nil,
                        metadata = McpRequestMeta()): McpRpcRequest =
  validateMethod(methodName)
  McpRpcRequest(kind: mcpNotification, methodName: methodName,
    params: newMcpParams(values, metadata), extraFields: newJObject())

proc newMcpMessageTransport*(request: McpTransportRequest,
                             notification: McpTransportNotification = nil,
                             close: McpTransportClose = nil): McpMessageTransport =
  if request.isNil:
    raise newMcpError("MCP transport request handler must not be nil")
  let notificationHandler = if notification.isNil:
    McpTransportNotification(proc (message: McpJsonRpcMessage):
        Future[void] {.async.} = discard) else: notification
  let closeHandler = if close.isNil:
    McpTransportClose(proc () = discard) else: close
  McpMessageTransport(requestHandler: request,
    notificationHandler: notificationHandler, closeHandler: closeHandler)

proc isClosed*(transport: McpMessageTransport): bool =
  transport.isNil or transport.closed

proc requireOpen(transport: McpMessageTransport) =
  if transport.isNil or transport.closed:
    raise newMcpError("MCP transport is closed")

proc requestAsync*(transport: McpMessageTransport,
                   message: McpJsonRpcMessage): Future[McpJsonRpcMessage] {.async.} =
  transport.requireOpen()
  if message.kind != mcpRequestMessage:
    raise newMcpError("MCP transport requests require a request message")
  await transport.requestHandler(message)

proc notifyAsync*(transport: McpMessageTransport,
                  message: McpJsonRpcMessage): Future[void] {.async.} =
  transport.requireOpen()
  if message.kind != mcpNotificationMessage:
    raise newMcpError("MCP transport notifications require a notification")
  await transport.notificationHandler(message)

proc close*(transport: McpMessageTransport) =
  if transport.isNil or transport.closed: return
  transport.closed = true
  transport.closeHandler()

proc newMcpPeer*(transport: McpMessageTransport,
                 metadata = McpRequestMeta()): McpPeer =
  if transport.isNil:
    raise newMcpError("MCP peer transport must not be nil")
  McpPeer(transport: transport,
    metadata: if metadata.protocolVersion.len == 0: newMcpRequestMeta() else:
      metadata, nextId: 1)

proc requirePeer(peer: McpPeer) =
  if peer.isNil or peer.transport.isNil:
    raise newMcpError("MCP peer must not be nil")

proc requestAsync*(peer: McpPeer, methodName: string,
                   values: JsonNode = nil): Future[McpWireResult] {.async.} =
  peer.requirePeer()
  let id = McpId(kind: mcpIntegerId, integerValue: peer.nextId)
  inc peer.nextId
  let request = newMcpRequest(id, methodName, values, peer.metadata)
  let message = await peer.transport.requestAsync(
    McpJsonRpcMessage(kind: mcpRequestMessage, request: request))
  case message.kind
  of mcpResponseMessage:
    if message.response.id != id:
      raise newMcpError("MCP transport returned a response for the wrong request")
    return message.response.result
  of mcpErrorMessage:
    if message.errorResponse.id != id:
      raise newMcpError("MCP transport returned an error for the wrong request")
    let error = message.errorResponse.error
    raise newMcpError(error.message, error.code, error.data)
  else:
    raise newMcpError("MCP transport returned a non-response message")

proc request*(peer: McpPeer, methodName: string,
              values: JsonNode = nil): McpWireResult =
  waitFor peer.requestAsync(methodName, values)

proc notifyAsync*(peer: McpPeer, methodName: string,
                  values: JsonNode = nil): Future[void] {.async.} =
  peer.requirePeer()
  let request = newMcpNotification(methodName, values, peer.metadata)
  await peer.transport.notifyAsync(
    McpJsonRpcMessage(kind: mcpNotificationMessage, request: request))

proc notify*(peer: McpPeer, methodName: string, values: JsonNode = nil) =
  waitFor peer.notifyAsync(methodName, values)

proc close*(peer: McpPeer) =
  if not peer.isNil: peer.transport.close()
