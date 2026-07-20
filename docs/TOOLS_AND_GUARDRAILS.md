# Tools and Guardrails

## Tools

Smith tools extend RubyLLM tools with:

- privilege enforcement
- custom authorization
- tool guardrails
- deadline enforcement
- tool-call budgeting
- tracing
- result capture (workflow-scoped tool output collection)

Example:

```ruby
class RefundCustomer < Smith::Tool
  category :action

  capabilities do
    privilege :elevated
  end

  authorize do |context|
    context[:account_id] && context[:role] == :elevated
  end

  def perform(context:, charge_id:, reason:)
    # call your billing system here
    { refunded: true, charge_id: charge_id, reason: reason }
  end
end
```

### Tool Compatibility (provider-aware tool selection)

Tools can declare which provider/endpoint combinations they tolerate. `Smith::Models::Normalizer` consults this metadata at chat construction and drops incompatible tools rather than letting the provider reject the request. Tools without a declaration are universally compatible (preserves existing behavior).

```ruby
class WebSearch < Smith::Tool
  # Allowlist form: specific providers, plus an OpenAI endpoint constraint.
  compatible_with :anthropic, :gemini, openai: :responses

  def perform(query:)
    # ...
  end
end
```

When `Smith.config.openai_api_mode = :auto` (the default) AND the tool requires `/v1/responses`, the normalizer instead sets `@params[:openai_api_mode] = :responses` so the routing prepend can dispatch via the Responses endpoint. When `:off`, the tool is dropped gracefully.

The compatibility spec is inherited by subclasses; subclasses can override by calling `compatible_with` again. The spec is consulted only by the Normalizer, so tools without a declaration retain their pre-refactor behavior.

### Tool Result Capture

Tools can declare a `capture_result` block to collect structured data during workflow execution. Smith stores captured data on the workflow and exposes it on `RunResult#tool_results`. Smith does not interpret the payload — the host app owns all projection.

```ruby
class WebSearch < Smith::Tool
  capture_result do |kwargs, result|
    { query: kwargs[:query], urls: extract_urls(result) }
  end

  def perform(query:)
    # search implementation
  end
end
```

After workflow execution:

```ruby
result = MyWorkflow.run_persisted!(key: "search:123", context: { topic: "AI" })
result.tool_results
# => [{ tool: "web_search", captured: { query: "AI trends", urls: ["https://..."] } }]
```

Captured tool results survive persistence — they are included in `to_state` and restored via `from_state`.

`tool_results` is designed for compact structured evidence (URLs, metadata, refs). Hosts should avoid storing large raw payloads there. If large tool outputs are needed, use artifacts and capture refs or metadata instead.

Capture is best-effort by default for backward compatibility. Hosts that cannot
complete a workflow checkpoint without captured evidence can opt into strict
capture:

```ruby
class VerifiedSearch < Smith::Tool
  capture_result(strict: true) do |kwargs, result|
    { query: kwargs.fetch(:query), urls: extract_urls(result) }
  end
end
```

Strict capture raises `Smith::ToolCaptureFailed` when no workflow collector is
active, the collector is not callable, the capture block fails or returns `nil`, or the collector rejects the
entry by raising an exception. A collector return value of `nil` or `false` is
accepted; delivery is rejected only when the collector raises. Best-effort
capture logs and continues as before.

Capture policy is declared per concrete tool class and is not inherited. This
preserves the historical opt-in contract and prevents a subclass from beginning
to capture or fail strictly without its own declaration.

Strict capture validates that a collector exists before `perform`, but the
capture block and collector run after `perform` returns. It is therefore
post-result evidence, not a pre-effect transaction or durable operation receipt.
`Smith::ToolCaptureFailed` is terminal: direct retry declarations are rejected,
and broad explicit retry classes such as `StandardError` do not override that
classification, because the external outcome may already have occurred. Hosts
must give side-effecting tools their own idempotent operation receipt and
reconciliation boundary before retrying them. Read-only tools can use strict
capture to fail closed when their result cannot be checkpointed.

### Host Invocation Context

Hosts can expose one opaque, execution-scoped value to tool adapters without
placing host identity or credentials in model arguments:

```ruby
Smith::Tool.with_invocation_context(execution_context) do
  workflow.advance
end

Smith::Tool.current_invocation_context
```

Smith does not inspect, serialize, or persist this value. The scope restores the
previous value even when execution raises, and the value propagates through
Smith-managed same-agent and heterogeneous parallel branches, durable composite
branch workers, and concurrent tool calls on chats returned by the Smith agent
entry points `chat`, `create`, `create!`, and `find`. Invocation context is
captured independently for each concurrent tool batch, so reusing a chat cannot
retain a previous execution's scope. Smith scopes only those chat instances;
requiring Smith does not alter raw RubyLLM chats. Arbitrary chats, threads, or
fibers created by host code are outside this boundary and must install their own
scope. Hosts remain responsible for using an immutable value and installing a
fresh context after durable resume; context-dependent adapters must fail closed
when no context is installed. Smith supports RubyLLM `>= 1.15, < 1.17` for this
integration and fails closed if the required per-chat tool execution hook is
unavailable. RubyLLM fiber concurrency still requires its optional `async`
dependency; Smith does not make that scheduler a runtime dependency.

You can still use RubyLLM agent tool wiring on your agents:

```ruby
class RefundAgent < Smith::Agent
  register_as :refund_agent
  model "gpt-4.1-nano"
  tools RefundCustomer
end
```

## Guardrails

Guardrails can be attached at either the workflow level or the agent level.

Workflow guardrails run before agent guardrails for inputs, and before agent guardrails for outputs as well.

Example:

```ruby
class SupportGuardrails < Smith::Guardrails
  def require_input(payload)
    raise "missing input" if payload.nil?
  end

  def sanitize_output(payload)
    raise "empty response" if payload.nil?
  end

  def require_ticket(kwargs)
    raise "ticket_id required" unless kwargs.dig(:context, :ticket_id)
  end

  input :require_input
  output :sanitize_output
  tool :require_ticket, on: [:refund_customer]
end
```

Attach them like this:

```ruby
class GuardedAgent < Smith::Agent
  register_as :guarded_agent
  model "gpt-4.1-nano"
  guardrails SupportGuardrails
end

class GuardedWorkflow < Smith::Workflow
  guardrails SupportGuardrails
  initial_state :idle
  state :done

  transition :finish, from: :idle, to: :done do
    execute :guarded_agent
  end
end
```
