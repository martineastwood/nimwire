## A small, current-spec MCP server framework for Nim.
##
## Import a focused module such as `nimwire/core`, `nimwire/server`, or
## `nimwire/transports/stdio` when an application does not need the others.

import ./nimwire/core
import ./nimwire/context
import ./nimwire/extensions
import ./nimwire/middleware
import ./nimwire/auth
import ./nimwire/mrtr
import ./nimwire/prompts
import ./nimwire/resources
import ./nimwire/schema
import ./nimwire/security
import ./nimwire/tasks
import ./nimwire/observability
import ./nimwire/transport
import ./nimwire/composition
import ./nimwire/server
import ./nimwire/subscriptions
import ./nimwire/testing
import ./nimwire/transports/stdio
import ./nimwire/transports/http
import ./nimwire/transports/inproc
import std/jsonutils

export core, context, extensions, middleware, auth, mrtr, prompts, resources, schema, security, tasks, observability, transport, composition, server, subscriptions,
  testing, stdio, http, inproc
export fromJsonHook, toJsonHook
