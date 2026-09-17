---
title: nimwire
description: Build Model Context Protocol servers in Nim with typed tools, resources, prompts, transports, and production controls.
template: splash
hero:
  title: The MCP server library for Nim
  tagline: Tools, resources, prompts, transports, and production controls for the Model Context Protocol, in native Nim code.
  actions:
    - text: Get started
      link: /introduction/
      variant: primary
      icon: right-arrow
    - text: View on GitHub
      link: https://github.com/martineastwood/nimwire
      variant: secondary
      icon: external
---

<div class="landing-shell not-content">
  <p class="landing-lede">Install nimwire, define a typed tool, and serve an MCP server from Nim. Expose resources and prompts, choose stdio or remote transports, and add authorization, cancellation, and observability when you deploy.</p>

  <section class="landing-terminal" aria-labelledby="landing-terminal-title">
    <div class="landing-terminal-bar">
      <div class="landing-terminal-dots" aria-hidden="true"><span></span><span></span><span></span></div>
      <span id="landing-terminal-title">echo.nim</span>
      <span class="landing-terminal-mode">stdio</span>
    </div>
    <pre class="not-content"><code><span class="kw">import</span> nimwire&#10;&#10;<span class="kw">type</span> EchoInput = <span class="kw">object</span>
  text*: string&#10;&#10;<span class="kw">let</span> server = mcpServer(<span class="str">&quot;nimwire-echo&quot;</span>, <span class="str">&quot;0.1.0&quot;</span>):
  server.tool <span class="str">&quot;echo&quot;</span>, <span class="str">&quot;Echo text back to the caller&quot;</span>,
    <span class="kw">proc</span> (input: EchoInput): string =
      input.text&#10;&#10;server.serveStdio()</code></pre>
  </section>

  <section class="landing-section" aria-labelledby="landing-runtime-title">
    <p class="landing-kicker">Native Nim</p>
    <h2 id="landing-runtime-title">A server you can ship in a binary</h2>
    <p class="landing-section-intro">Nimwire is ordinary Nim. It compiles into your program, speaks MCP over stdio, HTTP, or WebSocket, and does not require a hosted service or a language runtime beside the binary you already ship.</p>
    <div class="landing-grid">
      <article class="landing-card">
        <span class="landing-card-index">01</span>
        <h3>Typed tools from Nim</h3>
        <p>Write a Nim procedure. Nimwire derives the MCP input and output schemas, decodes arguments, and encodes the result.</p>
      </article>
      <article class="landing-card">
        <span class="landing-card-index">02</span>
        <h3>Stdio, HTTP, or WebSocket</h3>
        <p>Serve newline-delimited JSON-RPC over stdio for local clients, or use Streamable HTTP and WebSocket for remote ones.</p>
      </article>
      <article class="landing-card">
        <span class="landing-card-index">03</span>
        <h3>Your process, your rules</h3>
        <p>The server runs where you deploy it. Add bearer authorization, principal visibility, and security limits when clients connect over the network.</p>
      </article>
      <article class="landing-card">
        <span class="landing-card-index">04</span>
        <h3>Small, focused API</h3>
        <p>Start with <code>import nimwire</code>. Pull in focused modules such as <code>nimwire/transports/http</code> when the application needs them.</p>
      </article>
    </div>
  </section>

  <section class="landing-section" aria-labelledby="landing-work-title">
    <p class="landing-kicker">In your server</p>
    <h2 id="landing-work-title">From a handler to an MCP response</h2>
    <p class="landing-section-intro">Register tools, resources, and prompts on one server object. Nimwire handles discovery, schema generation, and protocol framing for the transport you choose.</p>
    <div class="landing-grid">
      <article class="landing-card">
        <span class="landing-card-index">01</span>
        <h3>Register tools</h3>
        <p>Expose Nim functions as MCP tools with compile-time schema derivation, or provide raw JSON when you need full control.</p>
      </article>
      <article class="landing-card">
        <span class="landing-card-index">02</span>
        <h3>Publish resources</h3>
        <p>Serve static text, generated data, binary contents, files, and URI templates that clients can read at runtime.</p>
      </article>
      <article class="landing-card">
        <span class="landing-card-index">03</span>
        <h3>Offer prompts</h3>
        <p>Return text, media, resource links, or embedded resources from typed string arguments with optional completion hooks.</p>
      </article>
      <article class="landing-card">
        <span class="landing-card-index">04</span>
        <h3>Run long work safely</h3>
        <p>Report progress, honor cancellation, set deadlines, and opt into MCP Tasks with in-memory or durable storage.</p>
      </article>
    </div>
  </section>

  <section class="landing-section" aria-labelledby="landing-customize-title">
    <p class="landing-kicker">Typed at the boundary</p>
    <h2 id="landing-customize-title">Nim types in, MCP schemas out</h2>
    <p class="landing-section-intro">A tool is a name, a description, and a callback over Nim parameters. Nimwire derives the JSON Schema the client sees and decodes arguments before your code runs.</p>
    <div class="landing-extend">
      <div class="landing-code">
        <div class="landing-code-bar"><span>weather.nim</span></div>
        <pre class="not-content"><code><span class="kw">import</span> nimwire&#10;&#10;<span class="kw">type</span> Weather = <span class="kw">object</span>
  temperature*: int
  condition*: string&#10;&#10;<span class="kw">let</span> server = mcpServer(<span class="str">&quot;weather&quot;</span>, <span class="str">&quot;1.0.0&quot;</span>):
  server.tool <span class="str">&quot;weather&quot;</span>, <span class="str">&quot;Get current weather for a city&quot;</span>,
    <span class="kw">proc</span> (city: string): Weather =
      discard city
      Weather(temperature: 16, condition: <span class="str">&quot;cloudy&quot;</span>)&#10;&#10;server.serveStdio()</code></pre>
      </div>
      <div class="landing-grid">
        <article class="landing-card">
          <span class="landing-card-index">01</span>
          <h3>Pause for client input</h3>
          <p>Return <code>input_required</code> from a tool, prompt, or resource call and resume on the next request with multi-round-trip input.</p>
        </article>
        <article class="landing-card">
          <span class="landing-card-index">02</span>
          <h3>Compose servers</h3>
          <p>Mount one MCP server inside another or route requests through an in-process transport for tests and modular apps.</p>
        </article>
        <article class="landing-card">
          <span class="landing-card-index">03</span>
          <h3>Extend the protocol</h3>
          <p>Register custom extensions and subscriptions when clients need capabilities beyond the core MCP surface.</p>
        </article>
        <article class="landing-card">
          <span class="landing-card-index">04</span>
          <h3>Observe every request</h3>
          <p>Attach logging, metrics, and tracing hooks so you can see what each client called and how long it took.</p>
        </article>
      </div>
    </div>
    <div class="landing-links">
      <a href="/guides/server-basics/" class="landing-link"><span>Server basics</span><small>Register tools and understand MCP responses.</small><span aria-hidden="true">↗</span></a>
      <a href="/guides/tools/" class="landing-link"><span>Typed tools</span><small>Derive MCP schemas from Nim procedures and types.</small><span aria-hidden="true">↗</span></a>
      <a href="/guides/resources/" class="landing-link"><span>Resources and prompts</span><small>Expose data and reusable messages to clients.</small><span aria-hidden="true">↗</span></a>
      <a href="/guides/transports/" class="landing-link"><span>Transports</span><small>Choose stdio, Streamable HTTP, WebSocket, or in-process delivery.</small><span aria-hidden="true">↗</span></a>
      <a href="/guides/mrtr/" class="landing-link"><span>Multi-round-trip input</span><small>Pause a call and resume after client input.</small><span aria-hidden="true">↗</span></a>
    </div>
  </section>

  <section class="landing-section landing-split" aria-labelledby="landing-interfaces-title">
    <div>
      <p class="landing-kicker">One library, several entry points</p>
      <h2 id="landing-interfaces-title">Use the surface that fits the job</h2>
      <p class="landing-section-intro">The same server object can serve stdio clients, remote HTTP connections, or in-process tests with the same tools, resources, and prompts.</p>
    </div>
    <div class="landing-links">
      <a href="/guides/quickstart/" class="landing-link"><span>serveStdio</span><small>Run a local MCP server over newline-delimited JSON-RPC.</small><span aria-hidden="true">↗</span></a>
      <a href="/guides/transports/" class="landing-link"><span>serveHttp</span><small>Accept Streamable HTTP requests from remote clients.</small><span aria-hidden="true">↗</span></a>
      <a href="/examples/echo-server/" class="landing-link"><span>Echo server</span><small>Copy a minimal stdio server and build from there.</small><span aria-hidden="true">↗</span></a>
      <a href="/guides/security/" class="landing-link"><span>Authorization</span><small>Add bearer tokens and principal-based visibility before you deploy.</small><span aria-hidden="true">↗</span></a>
    </div>
  </section>

  <section class="landing-start" aria-labelledby="landing-start-title">
    <div>
      <p class="landing-kicker">Start in a few lines</p>
      <h2 id="landing-start-title">Write the handler. Ship the binary.</h2>
      <p>Install nimwire with Nimble, create a small server file, and compile it into an executable your MCP client can launch or connect to.</p>
    </div>
    <pre><code><span class="landing-prompt">$</span> nimble install nimwire
<span class="landing-prompt">$</span> nim c echo.nim
<span class="landing-prompt">$</span> ./echo</code></pre>
  </section>

  <p class="landing-footer-link"><a href="/introduction/">Get Started</a> or <a href="https://github.com/martineastwood/nimwire">view nimwire on GitHub</a>.</p>
</div>
