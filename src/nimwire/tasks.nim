## Opt-in MCP tasks extension with scoped, expiring task storage.

import std/[asyncdispatch, base64, json, sysrand, tables, times]

import ./core
import ./context
import ./extensions
import ./schema

const mcpTasksExtensionName* = "io.modelcontextprotocol/tasks"

type
  McpTaskStatus* = enum
    mcpTaskQueued
    mcpTaskWorking
    mcpTaskInputRequired
    mcpTaskCompleted
    mcpTaskFailed
    mcpTaskCancelled

  McpTaskHandler* = proc (arguments: JsonNode,
                          context: McpContext): Future[McpResult] {.closure.}
  McpTaskCreateProc* = proc (task: McpTask) {.closure.}
  McpTaskGetProc* = proc (taskId, subject: string): McpTask {.closure.}
  McpTaskUpdateProc* = proc (task: McpTask) {.closure.}

  McpTask* = ref object
    taskId*: string
    status*: McpTaskStatus
    statusMessage*: string
    createdAt*: string
    lastUpdatedAt*: string
    ttlMs*: int
    pollIntervalMs*: int
    progress*: float
    hasProgress*: bool
    total*: float
    hasTotal*: bool
    inputRequests*: JsonNode
    result*: McpResult
    hasResult*: bool
    error*: McpRpcError
    hasError*: bool
    owner*: string
    expiresAt*: int64
    cancellation*: McpCancellation
    runtime: McpTaskRuntime

  McpTaskStore* = ref object
    ## Implement create/get/update for durable storage, or use the in-memory
    ## backend created by newMcpTaskStore.
    create*: McpTaskCreateProc
    get*: McpTaskGetProc
    update*: McpTaskUpdateProc
    tasks: Table[string, McpTask]
    ttlMs: int
    maxTasks: int
    pollIntervalMs: int

  McpTaskRuntime = ref object
    handler: McpTaskHandler
    arguments: JsonNode
    context: McpContext
    outputSchema: JsonNode
    running: bool

proc taskStatusName*(status: McpTaskStatus): string =
  case status
  of mcpTaskQueued: "queued"
  of mcpTaskWorking: "working"
  of mcpTaskInputRequired: "input_required"
  of mcpTaskCompleted: "completed"
  of mcpTaskFailed: "failed"
  of mcpTaskCancelled: "cancelled"

proc timestamp(seconds: int64): string =
  fromUnix(seconds).utc.format("yyyy-MM-dd'T'HH:mm:ss'Z'")

proc newTaskId(store: McpTaskStore): string =
  if store.create.isNil:
    var expired: seq[string]
    let now = int64(epochTime() * 1000.0)
    for taskId, task in store.tasks:
      if task.expiresAt > 0 and task.expiresAt <= now:
        expired.add taskId
    for taskId in expired:
      store.tasks.del(taskId)
  while true:
    result = "nimwire.task." & encode(urandom(32), safe = true)
    if result notin store.tasks: return

proc newMcpTaskStore*(ttlMs = 3600000, maxTasks = 10000,
                      pollIntervalMs = 5000): McpTaskStore =
  if ttlMs < 0: raise newMcpError("task ttlMs must be at least 0")
  if maxTasks < 1: raise newMcpError("task maxTasks must be positive")
  if pollIntervalMs < 0:
    raise newMcpError("task pollIntervalMs must be at least 0")
  McpTaskStore(tasks: initTable[string, McpTask](), ttlMs: ttlMs,
    maxTasks: maxTasks, pollIntervalMs: pollIntervalMs)

proc newMcpTaskStoreBackend*(create: McpTaskCreateProc,
                             get: McpTaskGetProc,
                             update: McpTaskUpdateProc,
                             ttlMs = 3600000,
                             pollIntervalMs = 5000): McpTaskStore =
  if create.isNil or get.isNil or update.isNil:
    raise newMcpError("task store backend must implement create, get, and update")
  if ttlMs < 0: raise newMcpError("task ttlMs must be at least 0")
  if pollIntervalMs < 0:
    raise newMcpError("task pollIntervalMs must be at least 0")
  McpTaskStore(create: create, get: get, update: update, ttlMs: ttlMs,
    pollIntervalMs: pollIntervalMs)

proc saveNew(store: McpTaskStore, task: McpTask) =
  if not store.create.isNil:
    store.create(task)
  else:
    if store.tasks.len >= store.maxTasks:
      raise newMcpError("task store is full")
    store.tasks[task.taskId] = task

proc saveUpdate(store: McpTaskStore, task: McpTask) =
  if not store.update.isNil: store.update(task)
  else: store.tasks[task.taskId] = task

proc lookup(store: McpTaskStore, taskId, subject: string): McpTask =
  if store.isNil or taskId.len == 0: return nil
  result = if not store.get.isNil: store.get(taskId, subject) else:
    store.tasks.getOrDefault(taskId)
  if result.isNil or result.owner != subject: return nil
  if result.expiresAt > 0 and int64(epochTime() * 1000.0) >= result.expiresAt:
    if store.get.isNil: store.tasks.del(taskId)
    return nil

proc taskOwner(context: McpContext): string =
  if not context.isNil and not context.principal.isNil:
    return context.principal.subject

proc newMcpTaskResult*(task: McpTask): McpResult =
  if task.isNil: raise newMcpError("task must not be nil")
  var fields = %*{
    "taskId": task.taskId,
    "status": task.status.taskStatusName,
    "createdAt": task.createdAt,
    "lastUpdatedAt": task.lastUpdatedAt,
    "ttlMs": if task.ttlMs > 0: %task.ttlMs else: newJNull()
  }
  if task.status == mcpTaskWorking and task.pollIntervalMs > 0:
    fields["pollIntervalMs"] = %task.pollIntervalMs
  if task.statusMessage.len > 0: fields["statusMessage"] = %task.statusMessage
  if task.hasProgress: fields["progress"] = %task.progress
  if task.hasTotal: fields["total"] = %task.total
  if task.status == mcpTaskInputRequired:
    fields["inputRequests"] = if task.inputRequests.isNil:
      newJObject() else: task.inputRequests
  if task.status == mcpTaskCompleted and task.hasResult:
    fields["result"] = task.result.fields
  if task.status == mcpTaskFailed and task.hasError:
    fields["error"] = toJson(task.error)
  newMcpResult(mcpTask, fields)

proc newMcpTaskGetResult*(task: McpTask): McpResult =
  if task.isNil: raise newMcpError("task not found")
  newMcpResult(mcpComplete, newMcpTaskResult(task).fields)

proc touch(task: McpTask) =
  task.lastUpdatedAt = timestamp(getTime().toUnix)

proc storeCancelled(store: McpTaskStore, task: McpTask, reason: string) =
  if task.status in {mcpTaskCompleted, mcpTaskFailed, mcpTaskCancelled}:
    return
  task.cancellation.cancel(reason)
  if not task.runtime.isNil: task.runtime.context.cancel(reason)
  task.status = mcpTaskCancelled
  task.statusMessage = if reason.len > 0: reason else: "Task cancelled"
  task.inputRequests = nil
  task.touch()
  store.saveUpdate(task)

proc fail(store: McpTaskStore, task: McpTask, code: int, message: string,
          data: JsonNode = nil) =
  if task.status == mcpTaskCancelled: return
  task.status = mcpTaskFailed
  task.statusMessage = message
  task.hasError = true
  task.error = newMcpRpcError(code, message, data)
  task.touch()
  store.saveUpdate(task)

proc runTask(store: McpTaskStore, task: McpTask): Future[void] {.async.} =
  let runtime = task.runtime
  try:
    if task.status == mcpTaskCancelled or task.cancellation.isCancelled: return
    let value = await runtime.handler(runtime.arguments, runtime.context)
    if task.status == mcpTaskCancelled or task.cancellation.isCancelled: return
    case value.resultType
    of mcpComplete:
      if not runtime.outputSchema.isNil:
        validateJsonValue(runtime.outputSchema, value.fields, "task result")
      task.result = value
      task.hasResult = true
      task.status = mcpTaskCompleted
      task.inputRequests = nil
      task.touch()
      store.saveUpdate(task)
    of mcpInputRequired:
      if "inputRequests" notin value.fields or
          value.fields["inputRequests"].kind != JObject:
        raise newMcpError("task input_required result needs inputRequests")
      task.inputRequests = value.fields["inputRequests"]
      task.status = mcpTaskInputRequired
      task.statusMessage = "Input required"
      task.touch()
      runtime.running = false
      store.saveUpdate(task)
    of mcpTask:
      raise newMcpError("task handlers must return complete or input_required")
  except McpError as error:
    runtime.running = false
    if task.status != mcpTaskCancelled and not task.cancellation.isCancelled:
      store.fail(task, error.code, error.msg, error.data)
  except CatchableError:
    runtime.running = false
    if task.status != mcpTaskCancelled and not task.cancellation.isCancelled:
      store.fail(task, mcpInternalErrorCode, "Internal server error")
  finally:
    if task.status in {mcpTaskCompleted, mcpTaskFailed, mcpTaskCancelled}:
      runtime.running = false

proc startMcpTask*(store: McpTaskStore, handler: McpTaskHandler,
                   arguments: JsonNode, context: McpContext,
                   outputSchema: JsonNode = nil): McpTask =
  if store.isNil: raise newMcpError("task store is not configured")
  if handler.isNil: raise newMcpError("task handler must not be nil")
  let owner = taskOwner(context)
  let now = getTime().toUnix
  let nowMs = int64(epochTime() * 1000.0)
  result = McpTask(taskId: store.newTaskId(), status: mcpTaskWorking,
    createdAt: timestamp(now), lastUpdatedAt: timestamp(now),
    ttlMs: store.ttlMs, pollIntervalMs: store.pollIntervalMs,
    owner: owner, expiresAt: if store.ttlMs > 0: nowMs + store.ttlMs else: 0,
    cancellation: newMcpCancellation())
  result.runtime = McpTaskRuntime(handler: handler, arguments: arguments,
    context: context, outputSchema: outputSchema, running: true)
  let task = result
  let previousProgress = if context.isNil: nil else: context.progress
  if not context.isNil:
    context.cancellation = result.cancellation
    context.deadlineAt = 0
    context.progress = proc (progress, total: float,
                             message: string): Future[void] {.async.} =
      task.progress = progress
      task.hasProgress = true
      if total >= 0:
        task.total = total
        task.hasTotal = true
      if message.len > 0: task.statusMessage = message
      task.touch()
      store.saveUpdate(task)
      if not previousProgress.isNil:
        await previousProgress(progress, total, message)
    context.notificationSender = nil
  store.saveNew(result)
  asyncCheck runTask(store, result)

proc getMcpTask*(store: McpTaskStore, taskId: string,
                 context: McpContext): McpTask =
  result = store.lookup(taskId, taskOwner(context))
  if result.isNil:
    raise newMcpError("task not found", mcpInvalidParamsCode)

proc updateMcpTask*(store: McpTaskStore, taskId: string,
                    responses: JsonNode, context: McpContext) =
  let task = store.getMcpTask(taskId, context)
  if responses.isNil or responses.kind != JObject:
    raise newMcpError("tasks/update inputResponses must be an object")
  if task.status != mcpTaskInputRequired or task.runtime.isNil:
    return
  if task.runtime.context.inputResponses.isNil or
      task.runtime.context.inputResponses.kind != JObject:
    task.runtime.context.inputResponses = newJObject()
  for key, response in responses.pairs:
    if key notin task.inputRequests: continue
    task.runtime.context.inputResponses[key] = response
    task.inputRequests.delete(key)
  if task.inputRequests.len == 0:
    task.status = mcpTaskWorking
    task.statusMessage = ""
    task.touch()
    task.runtime.running = true
    store.saveUpdate(task)
    asyncCheck runTask(store, task)
  else:
    task.touch()
    store.saveUpdate(task)

proc cancelMcpTask*(store: McpTaskStore, taskId: string,
                    context: McpContext) =
  let task = store.getMcpTask(taskId, context)
  store.storeCancelled(task, "Task cancelled")

proc newMcpTasksExtension*(store: McpTaskStore): McpExtension =
  if store.isNil: raise newMcpError("task store must not be nil")
  result = newMcpExtension(mcpTasksExtensionName,
    requiresClientCapability = true)
  result.addExtensionMethod("tasks/get",
    proc (params: JsonNode, context: McpContext): Future[McpResult] {.async.} =
      let taskId = requiredString(params, "taskId", "tasks/get params")
      store.getMcpTask(taskId, context).newMcpTaskGetResult())
  result.addExtensionMethod("tasks/update",
    proc (params: JsonNode, context: McpContext): Future[McpResult] {.async.} =
      let taskId = requiredString(params, "taskId", "tasks/update params")
      if "inputResponses" notin params:
        raise newMcpError("tasks/update requires inputResponses")
      store.updateMcpTask(taskId, params["inputResponses"], context)
      newMcpResult(mcpComplete))
  result.addExtensionMethod("tasks/cancel",
    proc (params: JsonNode, context: McpContext): Future[McpResult] {.async.} =
      let taskId = requiredString(params, "taskId", "tasks/cancel params")
      store.cancelMcpTask(taskId, context)
      newMcpResult(mcpComplete))
