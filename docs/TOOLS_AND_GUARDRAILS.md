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

`params` and Ruby keyword declarations describe the model-facing tool schema.
Tool arguments remain untrusted. A host adapter must validate its own input
contract inside `perform` before external work and return a bounded failure
payload for expected validation or provider failures. It should raise for
configuration, programming, authorization-integrity, or durability failures.
Smith applies policy and budgeting around that host boundary; it does not
interpret a host's input schema or failure envelope.

### Bounded Completion

The default exhaustion policy remains fail-fast:

```ruby
class SearchAgent < Smith::Agent
  tools WebSearch
  budget tool_calls: 3
  tool_budget_exhaustion :raise
end
```

Read-only agents that can finish from partial evidence may opt into graceful
completion:

```ruby
class SearchAgent < Smith::Agent
  tools WebSearch
  budget tool_calls: 3
  tool_budget_exhaustion :complete
end
```

Hosts with signed per-tool policy can replace the aggregate integer with an
exact budget:

```ruby
budget = Smith::Tool::CallBudget.new(
  total: 4,
  tool_limits: {
    "weather_forecast" => 1,
    "web_search" => 3
  }
)

Smith::Tool.with_call_budget(budget, on_exhaustion: :complete) do
  workflow.advance
end
```

An agent may use the same value in `budget tool_calls: budget`. The enclosing
allowance is a shared transition cap. Same-agent parallel branches,
heterogeneous fan-out branches, and repeated optimizer participants narrow that
shared cap to their own agent budget; they do not receive independent copies.
Batch admission checks the aggregate and per-tool counters atomically before
any tool runs.

`:complete` requires a finite budget and RubyLLM 1.16.0. While more than one
call remains, Smith permits the provider to return multiple calls in one
response; the final remaining call uses the single-call provider hint. Smith
still executes an admitted batch sequentially and advances the provider loop
iteratively without recursive Ruby stack growth. The provider control is
advisory: every returned batch is checked atomically. A batch larger than the
remaining allowance executes no calls, receives one tool result for every
requested call id, and is followed by one completion with the tools removed.
Exact exhaustion follows the same tool-disabled completion path. The original
tools, call preferences, and concurrency setting are restored in `ensure`.

The allowance counts model-requested calls, including unavailable tool names.
An exact admitted Smith tool receives a one-use admission so it is not charged
twice; a nested Smith tool must consume its own allowance. Batch admission
reserves the effective workflow tool budget before any tool runs, then
reconciles calls rejected before `perform`. Calls on the same bounded chat
cannot complete concurrently or reenter through callbacks. The opt-in bounded
policy accepts only `Smith::Tool` bindings so Smith can enforce these guarantees;
ordinary RubyLLM tools retain their existing behavior when the policy is not
enabled. Raw provider params may not override `tools`, tool choice, or parallel
tool-call controls while bounded completion is active. Smith supplies the
provider call-cardinality hint only when the RubyLLM model registry advertises
`parallel_tool_calls`, or when the selected Responses endpoint supports that
control. Otherwise the hint is omitted and Smith's atomic local batch admission
remains authoritative.

This is not a durable model-loop checkpoint. A host still needs an operation
receipt and reconciliation boundary before replaying side effects or recovering
mid-loop from process loss.

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

When `Smith.config.openai_api_mode = :auto` (the default) AND the tool requires
`/v1/responses`, the normalizer sets `@params[:openai_api_mode] = :responses` so
the routing prepend can dispatch via the compatible endpoint. This applies with
or without model thinking. When `:off`, the tool is dropped gracefully.

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
when no context is installed. Smith supports RubyLLM `1.16.0` for this
integration and fails closed if the required per-chat tool execution hook is
unavailable. RubyLLM fiber concurrency still requires its optional `async`
dependency; Smith does not make that scheduler a runtime dependency.

Smith applies the same model normalization and tool-compatibility routing to
persisted chats returned by `create`, `create!`, and `find` as it does to direct
`chat` construction. The configured transport provider is authoritative even
when the model identifier is commonly associated with another provider;
provider-specific endpoint assumptions are cleared when the transport changes.
Reserved Smith inputs are available before persisted-chat dynamic
configuration runs. When OpenAI endpoint routing is automatic, Smith compares
the compatible tool counts in one pass and selects Responses only when it
preserves a strictly larger subset; a tie keeps the current endpoint. A
specific forced tool takes precedence when only one enabled endpoint can carry
it. If normalization removes a specifically forced tool, Smith clears that
stale choice and attributes the reset only to that selected tool. An
endpoint-constrained tool routed to OpenAI Responses inherits the current
non-streaming Responses contract; callers requesting streaming receive the
documented explicit unsupported error rather than silent Chat Completions
fallback.

Bounded completion ownership and tool-call reservations mask asynchronous
interrupts while installing and restoring process-local state. User work runs
with normal interrupt delivery, and the protected cleanup finishes before an
interrupt can escape the boundary.

During an executing Smith tool, hosts can also read immutable normalized call
metadata:

```ruby
invocation = Smith::Tool.current_invocation
invocation.tool_call_id
invocation.tool_name
invocation.ordinal
invocation.batch_ordinal
invocation.batch_size
```

`tool_call_id` is RubyLLM's normalized call identifier. Some adapters preserve
an identifier supplied by the model provider and others synthesize one while
parsing, so it is correlation metadata, not a provider idempotency key or
authoritative replay proof. `ordinal` is allocated from one thread-safe sequence
shared by every Smith-managed chat, branch, thread, and fiber inside the current
host invocation scope.

Hosts that reconstruct an execution may supply an explicit next ordinal:

```ruby
sequence = Smith::Tool::InvocationSequence.new(next_ordinal: 12)
Smith::Tool.with_invocation_context(context, invocation_sequence: sequence) do
  workflow.advance
end
```

Smith does not persist that sequence. A durable host must derive the resume
ordinal from its own authoritative ledger and must not resume a model/tool loop
unless it can also reconstruct the exact provider transcript and operation
outcomes. Without an invocation context Smith uses a chat-local sequence for
ordinary non-hosted tool execution.

Durable hosts may atomically admit the complete Smith-managed subset of each
provider batch before Smith dispatches any Smith tool:

```ruby
Smith::Tool.with_invocation_context(
  context,
  invocation_sequence: sequence,
  batch_admitter: ->(requests:) { receipts.admit_batch!(requests) },
  failure_handler: ->(request:, error:) { receipts.fail_dispatch!(request, error) }
) do
  workflow.advance
end
```

Smith snapshots provider-batch membership once using native `Hash` operations
after admitting its native cardinality, then verifies the owned snapshot retained
that cardinality and validates provider-call identity. The complete provider
batch is limited to 100 calls and 1 MiB of normalized UTF-8 call metadata before
host admission; aggregate capture stops as soon as the metadata limit is crossed,
before reading that crossing call's arguments. Every
model-requested call, including unavailable and plain RubyLLM names, is reserved
against the active Smith budget. For registered
`Smith::Tool` targets Smith owns a bounded, acyclic, JSON-compatible argument
snapshot and rejects duplicate string-equivalent object keys. It materializes
one immutable dispatch collection from those snapshots before host admission.
The batch callback receives the complete ordered frozen array of immutable
`InvocationRequest` values for the Smith targets. Returning normally asserts
that the host admitted that complete subset durably. Raising asserts that none
of that subset was admitted: Smith dispatches no Smith tool and does not invoke
the per-call failure handler. A host must therefore make callback return/raise
agree with its own atomic transaction.

Passing the provider collection and tool argument graph into this boundary
transfers temporary ownership to Smith for the duration of capture. The provider
and host must not mutate those containers concurrently. Smith admits native
cardinality before copying and rejects a copy whose cardinality changed, but it
deliberately does not freeze or otherwise mutate caller-owned containers.
Sequential mutation after capture cannot alter the owned batch.

Smith masks asynchronous interruption while the host admission callback runs and
while its successful return is recorded in the local batch state; this prevents
an interrupt from separating a committed host admission from Smith's dispatch
decision. The callback must therefore be bounded and timeout-controlled. It
should perform only the host's local atomic admission work, not provider I/O or
an unbounded remote request.

Configuring `batch_admitter` requires `failure_handler`. Smith rejects an
admission callback without the corresponding terminal-failure callback before
execution begins, so a host cannot opt into durable admission without also
providing a way to terminate every admitted receipt.

Unavailable calls and tools implemented directly as `RubyLLM::Tool` do not
produce `InvocationRequest` values and are not covered by the host callback.
They still consume the bounded allowance. A mixed batch can therefore be
host-atomic only for its Smith-managed subset; hosts that require a durable
receipt for every executable tool must bind only `Smith::Tool` adapters.

After a callback returns, RubyLLM executes Smith's immutable admitted
collection, not the caller-owned collection. Adding, removing, renaming, or
mutating source calls after the snapshot therefore cannot alter the admitted
execution. Smith still verifies that the exact registered tool object matches
the admitted target. Each admitted call acquires one atomic dispatch claim;
callback re-entry for the same admission is rejected before `perform` and cannot
repeat its effect. The managed dispatch also owns a one-use execution authority.
Calling a Smith tool directly from a provider callback or from another managed
Smith tool fails closed; nested execution requires a future separately admitted
invocation primitive. Tool replacement, a RubyLLM argument rejection, a callback
failure before `Smith::Tool#perform`, or a Smith deadline that expires before
`perform` raises `Smith::ToolDispatchRejected`. Smith attempts to notify every
unsettled admitted sibling in one bounded pass even when one failure handler
call raises. The callback must be idempotent because a failed notification
remains unsettled for conservative host recovery. Errors from a failed terminal
callback surface as `Smith::ToolFailureNotificationFailed` and are never
transition-retryable. The error retains both the dispatch failure and the host
callback failure.

For an admitted provider-batch call, pre-execution hooks and tool guardrails
receive an inspection-only argument Hash. The full admitted argument graph is
Smith-owned and frozen, so policy inspection cannot rewrite the values that
reach `perform`. Errors raised from inside `perform`, including
`Smith::DeadlineExceeded`, do not prove that external work was absent and retain
their original type. Process-fatal exceptions are never converted into receipt
outcomes or terminal callbacks: an admitted receipt remains unresolved and the
durable host must reconcile it before any resume decision. Smith never
automatically replays that uncertain work. Failure-handler errors propagate
because Smith cannot claim the host recorded a terminal outcome when it did not.

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
