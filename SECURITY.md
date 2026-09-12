# nimwire security checklist

Before deploying a server, verify the following for every transport and
example:

- Keep Streamable HTTP behind TLS and a trusted reverse proxy.
- Set HTTP body, nesting, host, origin, timeout, and concurrency limits.
- Set `McpSecurityLimits` for tool count, result size, concurrent calls, and
  stdio line size where the deployment needs bounded resources.
- Enable `McpAuthorizationConfig` for remote servers, validate issuer,
  audience, expiry, and scopes in the verifier, and never forward bearer
  credentials to a downstream service.
- Treat tool, resource, prompt, and content annotations as untrusted metadata.
- Use `redactJson`, `redactHeaderValue`, and `redactBearerToken` before writing
  diagnostics. The default server error log contains method names only.
- Keep URL-mode elicitation on HTTPS and do not prefetch or navigate URLs.
- Use `safeResourcePath` or `newFileResourceTemplate` for filesystem access;
  do not concatenate user paths directly.
- Ensure every handler cooperatively calls `context.checkCancelled()` around
  subprocesses, network calls, and other interruptible work.
- Run the parser/security harnesses and review all example configuration before
  publishing a service.

The library supplies policy hooks; it does not implement an OAuth provider,
credential store, subprocess sandbox, or TLS termination layer.
