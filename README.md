# Smith

Workflow-first multi-agent orchestration for Ruby.

Smith gives you a disciplined way to build agent systems that are explicit, inspectable, and operationally sane. Instead of hiding orchestration inside prompts, it lets you model the work as a workflow with named states, named transitions, budgets, guardrails, tool policy, persistence hooks, artifacts, tracing, and composable multi-agent patterns.

> [!WARNING]
> `smith` is not published yet and is still under active development.
> Expect API changes, contract tightening, and sharp edges.
> If you want to build on it early, pin a commit and verify behavior against the runtime specs and [`spec/SPEC_MATRIX.md`](./spec/SPEC_MATRIX.md).

## Why The Name

Smith is named after Agent Smith from *The Matrix*.

The reference fits the kind of systems this library is built for across Smith's full role in the films: control, enforcement, replication, propagation, coordination, containment pressure, and a system that becomes more dangerous as it becomes more autonomous and harder to constrain. That is closer to real agent software than most friendly assistant demos: multiple actors, repeated delegation, expanding scope, and failure modes that matter once the system has real consequences.

Smith is built for that layer: not just "call a model," but manage agent behavior as a system.

## Why Use Smith

Most agent demos look good until you need one of these:

- explicit control flow instead of "the prompt told the model what to do"
- repeatable failure behavior
- tool authorization and guardrails
- budget and deadline enforcement
- parallel fan-out with controlled accounting
- nested workflows and reusable subflows
- evaluator-optimizer and orchestrator-worker loops
- persistence and resume at workflow boundaries
- artifacts for large outputs
- tracing and best-known token/cost accounting

Smith is built for that layer.

It is especially useful when you want to:

- turn one-off prompting into a real application workflow
- keep orchestration in Ruby instead of burying everything in model text
- compose multiple agents without losing control of budgets, deadlines, and failure semantics
- let host apps own storage, queues, retries, and long-lived durability

## What Smith Is

- A Ruby library for workflow-first agent orchestration
- Built on top of `RubyLLM`, not a replacement for it
- In-process and host-controlled
- Good for application-level orchestration where you want explicit state and explicit control

## What Smith Is Not

- Not a hosted runtime
- Not a durable workflow engine by itself
- Not a job queue
- Not a billing-grade cost system
- Not a replacement for your app's persistence, retries, or deployment platform

Your application still owns:

- persistence
- job execution
- retries at the host/process level
- tenant isolation policy
- provider credentials and provider-level configuration

## What You Can Build

With the current surface you can build:

- a single guarded agent behind a workflow boundary
- sequential multi-step flows
- classifier routers
- bounded parallel fan-out
- reusable subflows through nested workflows
- generator/evaluator loops
- orchestrator/worker systems
- workflows that store big outputs as artifact refs
- resumable flows using `to_state` / `.from_state`

## Value In One Minute

Here is the practical shift Smith gives you.

Without Smith, a typical app ends up with:

- a prompt string
- an LLM call
- some ad hoc branching around the response
- unclear failure handling
- no workflow state

With Smith, the same job becomes an explicit workflow with real structure:

```ruby
class ReplyContext < Smith::Context
  persist :user_message

  inject_state do |persisted|
    "User message: #{persisted[:user_message]}"
  end
end

class ReplyAgent < Smith::Agent
  register_as :reply_agent
  model "gpt-4.1-nano"

  instructions do |_context|
    "Write a concise, professional reply."
  end
end

class ReplyWorkflow < Smith::Workflow
  context_manager ReplyContext
  initial_state :idle
  state :done
  state :failed

  transition :reply, from: :idle, to: :done do
    execute :reply_agent
    on_failure :fail
  end
end

result = ReplyWorkflow.new(
  context: { user_message: "I was charged twice for the same invoice." }
).run!

result.state
# => :done

result.output
# => final assistant output

result.steps
# => [{ transition: :reply, from: :idle, to: :done, output: ... }]
```

That buys you immediately:

- explicit workflow state
- explicit success and failure routing
- a step log you can inspect
- a clean place to add budgets, tools, guardrails, tracing, persistence, and artifacts later

## Installation

`smith` is not on RubyGems yet.

Use a local path:

```ruby
# Gemfile
gem "smith", path: "../smith"
```

Or a git source from your own remote:

```ruby
# Gemfile
gem "smith", git: "ssh://git@your-git-host/your-org/smith.git"
```

Then install:

```bash
bundle install
```

## Host Verification

After adding Smith to your bundle, verify the integration.

### Plain Ruby

```bash
smith doctor              # offline verification
smith doctor --live       # includes real provider call
smith doctor --durability # includes persistence round-trip
smith install             # scaffold config/smith.rb
```

### Rails

```bash
bin/rails smith:doctor              # offline verification
bin/rails smith:doctor:live         # includes real provider call
bin/rails smith:doctor:durability   # includes persistence round-trip
bin/rails smith:install             # scaffold config/initializers/smith.rb
```

Or use the Rails generator:

```bash
bin/rails generate smith:install
```

### What Doctor Verifies

- **Baseline** (always): Smith loads, Ruby version, RubyLLM loads, minimal workflow boots
- **Configuration** (always): logger, artifacts, tracing, pricing — warns if missing
- **Serialization** (with `--durability`): to_state, JSON round-trip, from_state, resume
- **Durability** (with `--durability`): host persistence adapter round-trip and resumed execution
- **Persistence** (with `--profile rails_persistence`): ActiveRecord, DB connection, RubyLLM persistence surface, schema
- **Live** (with `--live`): real provider call against configured RubyLLM model

Doctor is offline by default. Live verification and persistence checks are opt-in.

### Built-In Persistence Adapters

For durability verification, Smith supports these first-class adapter modes:

- `:rails_cache` for standard Rails cache integration
- `:solid_cache` as a Rails-cache alias when your cache backend is Solid Cache
- `:cache_store` for any cache-like store that responds to `write`, `read`, and `delete`
- `:redis` for a Redis client
- `:active_record` for a keyed ActiveRecord model such as `WorkflowState`

`:rails_cache` and `:solid_cache` are only as durable as the configured Rails cache backend.
If Rails is using `ActiveSupport::Cache::MemoryStore`, Smith can round-trip in-process but that storage will not survive restarts, and doctor will warn accordingly.
The same warning applies to `:cache_store` if you point it at a process-local memory backend.

Example Rails config:

```ruby
Smith.configure do |config|
  config.persistence_adapter = :rails_cache
  config.persistence_options = { namespace: "smith" }
end
```

If the workflow should begin with a deterministic conversation turn, you can seed that session history directly on the workflow:

```ruby
class SeededReplyWorkflow < Smith::Workflow
  seed_messages do |ctx|
    [{ role: :user, content: ctx[:user_message] }]
  end

  initial_state :idle
  state :done

  transition :reply, from: :idle, to: :done do
    execute :reply_agent
  end
end
```

Example Redis config:

```ruby
Smith.configure do |config|
  config.persistence_adapter = :redis
  config.persistence_options = {
    redis: Redis.new(url: ENV.fetch("REDIS_URL")),
    namespace: "smith"
  }
end
```

Example ActiveRecord config:

```ruby
Smith.configure do |config|
  config.persistence_adapter = :active_record
  config.persistence_options = {
    model: WorkflowState,
    key_column: :key,
    payload_column: :payload
  }
end
```

You can still provide a custom adapter object if your host app already has its own persistence API.
It just needs to implement:

- `store(key, payload)`
- `fetch(key)`
- `delete(key)`

## Quickstart

The setup model is:

1. configure your provider through `RubyLLM`
2. optionally configure Smith runtime services
3. define an agent
4. define a workflow
5. run it

### What Is Actually Required

To make a real Smith workflow run, you need:

- working `RubyLLM` provider setup
- at least one `Smith::Agent` with a `model`
- a `register_as` name for any agent a workflow will execute
- a `Smith::Workflow` with at least one transition

Everything else is optional at first:

- `Smith.configure`
- budgets
- guardrails
- context management
- tracing
- artifacts
- pricing

### 1. Configure RubyLLM

Smith depends on `RubyLLM`.
It does not replace provider setup.

Minimal OpenAI example:

```ruby
require "ruby_llm"

RubyLLM.configure do |config|
  config.openai_api_key = ENV.fetch("OPENAI_API_KEY")
  config.default_model = "gpt-4.1-nano"
end
```

The exact keys change by provider, but the layering does not:

- RubyLLM owns provider credentials and default provider behavior
- Smith owns orchestration on top of that

If you skip `Smith.configure`, you still need:

```ruby
require "smith"
```

### 2. Optionally Configure Smith

`Smith.configure` is global runtime config for orchestration concerns:

- artifacts
- tracing
- pricing
- logging

Minimal example:

```ruby
require "logger"
require "smith"

Smith.configure do |config|
  config.logger = Logger.new($stdout)
  config.trace_adapter = Smith::Trace::Memory.new
  config.artifact_store = Smith::Artifacts::Memory.new

  config.pricing = {
    "gpt-4.1-nano" => {
      input_cost_per_token: 0.0000001,
      output_cost_per_token: 0.0000004
    }
  }
end
```

You do not need all of that to get started.
For a first run, `Smith.configure` can be omitted entirely.

### 3. Define An Agent

```ruby
class SupportReplyAgent < Smith::Agent
  register_as :support_reply_agent
  model "gpt-4.1-nano"

  instructions do |_context|
    "Write a concise, calm support reply with a concrete next step."
  end
end
```

### 4. Define A Workflow

```ruby
class SupportReplyContext < Smith::Context
  persist :ticket_id, :user_message

  inject_state do |persisted|
    <<~TEXT
      Ticket: #{persisted[:ticket_id]}
      User message: #{persisted[:user_message]}
    TEXT
  end
end

class SupportReplyWorkflow < Smith::Workflow
  context_manager SupportReplyContext
  initial_state :idle
  state :done
  state :failed

  transition :reply, from: :idle, to: :done do
    execute :support_reply_agent
    on_failure :fail
  end
end
```

### 5. Run It

```ruby
result = SupportReplyWorkflow.new(
  context: {
    ticket_id: "T-1042",
    user_message: "I was charged twice for the same invoice."
  }
).run!

result.state
# => :done

result.output
# => final workflow output
```

The immediate value is not just "call a model". It is that the call now happens inside:

- an explicit workflow state machine
- a step log
- a standard failure path
- a result object with cumulative best-known totals

### Passing Input

The normal public way to pass input into a workflow is exactly what the quickstart does:

1. pass data through `context:`
2. declare which keys matter with `persist`
3. turn those keys into agent-visible input with `inject_state`

If you need conversation history rather than just structured workflow input, that history lives in `session_messages` in persisted workflow state and comes back through `.from_state`.

If a workflow should start from a deterministic first turn, use `seed_messages` on the workflow. Seeded messages are only added for newly initialized workflows and do not rerun on restore.

## Core Concepts

### `Smith::Agent`

Use `Smith::Agent` when you want RubyLLM agents plus Smith-specific operational controls.

Smith adds:

- `budget`
- `guardrails`
- `output_schema`
- `data_volume`
- `fallback_models`
- `register_as`

It still keeps the RubyLLM agent surface, so you can continue using things like:

- `model`
- `tools`
- `instructions`
- `temperature`
- `thinking`

Example:

```ruby
class ResearchSummarySchema
  # Replace this with your real RubyLLM schema object/class.
  # The intended shape here is something like:
  # { summary: "...", sources: ["..."] }
end

class ResearchAgent < Smith::Agent
  register_as :research_agent

  model "gpt-4.1-nano"
  temperature 0.2

  budget token_limit: 20_000, cost: 0.75, wall_clock: 20, tool_calls: 5
  fallback_models "gpt-4.1-mini"
  output_schema ResearchSummarySchema

  instructions do |_context|
    "Research the topic and return a concise, factual answer."
  end
end
```

Notes:

- `output_schema` is passed through to RubyLLM schema support for providers that support structured outputs.
- `thinking` is inherited from RubyLLM and forwards reasoning/thinking controls to providers that support them.
- use `thinking` with reasoning-capable models, for example:

```ruby
class DeepReasoningAgent < Smith::Agent
  register_as :deep_reasoning_agent
  model "o4-mini"
  thinking effort: :medium, budget: 2_048
end
```

### `Smith::Workflow`

Use `Smith::Workflow` to define the actual orchestration graph.

It gives you:

- states
- transitions
- workflow budgets
- max transition bounds
- workflow-level guardrails
- context management
- stepwise execution
- persistence and resume

Example:

```ruby
class ResearchWorkflow < Smith::Workflow
  initial_state :idle
  state :researching
  state :done
  state :failed

  budget total_tokens: 150_000, total_cost: 2.50, wall_clock: 300, tool_calls: 20
  max_transitions 12

  transition :start, from: :idle, to: :researching do
    execute :research_agent
    on_success :finish
    on_failure :fail
  end

  transition :finish, from: :researching, to: :done
end
```

### `RunResult`

`workflow.run!` returns a result object with:

- `state`
- `output`
- `steps`
- `total_cost`
- `total_tokens`
- `context`
- `session_messages`

Those totals are cumulative best-known workflow totals, including resumed execution and nested roll-up, not just the last `run!` segment.

Convenience helpers:

- `terminal_output`
- `last_error`
- `failed_transition`
- `failure_detail`

`context` and `session_messages` are returned as final-state snapshots for host projection code. Mutating them does not mutate workflow internals.

Typical successful step entry:

```ruby
{
  transition: :reply,
  from: :idle,
  to: :done,
  output: { "status" => "ok" }
}
```

Typical failed step entry:

```ruby
{
  transition: :reply,
  from: :idle,
  to: :done,
  error: #<Smith::AgentError ...>
}
```

### `advance!`

Use `advance!` when you want stepwise execution instead of running the workflow to completion in one call.

```ruby
workflow = ResearchWorkflow.new

first_step = workflow.advance!
workflow.state
# => :researching

result = workflow.run!
workflow.state
# => :done
```

This shows the mixed mode clearly:

- `advance!` executes one step
- `run!` then continues from the current workflow state
- in this example, `run!` performs the remaining work and finishes the workflow

This is useful when your host app wants to inspect or persist state between step boundaries.

## Pattern Guide

Use this as the quick selection rule:

| If you need... | Use... |
| --- | --- |
| One guarded model call behind a workflow boundary | A single `transition` with `execute` |
| Fixed sequential stages | `pipeline` |
| Classification-based branching | `route` |
| Fan-out across N parallel calls | `execute ..., parallel: true, count: N` |
| Reusable subflows | `workflow ChildWorkflow` |
| Iterative improve-and-judge loops | `optimize` |
| An orchestrator delegating structured tasks to workers | `orchestrate` |

The rest of this README walks through those in increasing complexity.

## Example 1: Single-Step Workflow

Use this when you want one agent call with real workflow semantics around it.

```ruby
class TicketReplyAgent < Smith::Agent
  register_as :ticket_reply_agent
  model "gpt-4.1-nano"

  instructions do |_context|
    "Draft a support reply that is concise, calm, and actionable."
  end
end

class TicketReplyWorkflow < Smith::Workflow
  initial_state :idle
  state :done
  state :failed

  transition :reply, from: :idle, to: :done do
    execute :ticket_reply_agent
    on_failure :fail
  end
end

result = TicketReplyWorkflow.new.run!
```

Why this is useful even when it looks small:

- you get a named transition
- failures route consistently
- the step is visible in `result.steps`
- you can later add budgets, guardrails, persistence, context, or tracing without rewriting the shape

## Example 2: Multi-Step Workflow With Explicit Success Paths

Use this when you want sequential work, but each stage still needs its own step boundary and failure semantics.

```ruby
class IntakeAgent < Smith::Agent
  register_as :intake_agent
  model "gpt-4.1-nano"
end

class DraftAgent < Smith::Agent
  register_as :draft_agent
  model "gpt-4.1-nano"
end

class ReviewWorkflow < Smith::Workflow
  initial_state :idle
  state :triaged
  state :drafted
  state :done
  state :failed

  transition :intake, from: :idle, to: :triaged do
    execute :intake_agent
    on_success :draft
    on_failure :fail
  end

  transition :draft, from: :triaged, to: :drafted do
    execute :draft_agent
    on_success :finish
    on_failure :fail
  end

  transition :finish, from: :drafted, to: :done
end
```

Value:

- no hidden control flow
- no prompt-level "now do step 2"
- if step 1 or step 2 fails, the failure is a real workflow event, not an accidental provider exception leaking through

## Example 3: Pipeline

Use `pipeline` when the flow is mechanically sequential and you do not want to hand-write each transition.

```ruby
class ResearchAgent < Smith::Agent
  register_as :research_agent
  model "gpt-4.1-nano"
end

class OutlineAgent < Smith::Agent
  register_as :outline_agent
  model "gpt-4.1-nano"
end

class DraftAgent < Smith::Agent
  register_as :draft_agent
  model "gpt-4.1-nano"
end

class ArticleWorkflow < Smith::Workflow
  initial_state :idle
  state :drafted
  state :failed

  pipeline :draft_article, from: :idle, to: :drafted do
    stage :research, execute: :research_agent
    stage :outline, execute: :outline_agent
    stage :draft, execute: :draft_agent
    on_failure :fail
  end
end
```

Why pipeline matters:

- you still get real step boundaries
- each stage is still visible in the step log
- the last stage output becomes the workflow result
- the generated transitions are explicit and stable, rather than hidden in a loop

Note: `on_failure` inside the `pipeline` block applies to the generated pipeline transitions as a whole.
It is not a separate per-stage custom failure policy surface.

## Example 4: Router

Use `route` when a classifier decides which specialist transition should run next.

The classifier output must be a hash that includes:

- `:route`
- `:confidence`

Example:

```ruby
class RouteDecisionSchema
  # Replace this with your real RubyLLM schema object/class.
  # Intended shape:
  # { route: :refund, confidence: 0.91 }
end

class TriageAgent < Smith::Agent
  register_as :triage_agent
  model "gpt-4.1-nano"
  output_schema RouteDecisionSchema

  instructions do |_context|
    <<~TEXT
      Return a Hash with:
      - :route => one of the declared route keys
      - :confidence => a float between 0.0 and 1.0
    TEXT
  end
end

class RefundAgent < Smith::Agent
  register_as :refund_agent
  model "gpt-4.1-nano"
end

class GeneralSupportAgent < Smith::Agent
  register_as :general_support_agent
  model "gpt-4.1-nano"
end

class SupportRouterWorkflow < Smith::Workflow
  initial_state :idle
  state :triaged
  state :refund_handled
  state :general_handled
  state :failed

  transition :classify, from: :idle, to: :triaged do
    route :triage_agent,
          routes: {
            refund: :handle_refund,
            support: :handle_general
          },
          confidence_threshold: 0.75,
          fallback: :handle_general
    on_failure :fail
  end

  transition :handle_refund, from: :triaged, to: :refund_handled do
    execute :refund_agent
    on_failure :fail
  end

  transition :handle_general, from: :triaged, to: :general_handled do
    execute :general_support_agent
    on_failure :fail
  end
end
```

Why this is better than "classifier prompt + if/else outside":

- route resolution is part of the workflow contract
- confidence thresholds are explicit
- invalid router outputs fail as workflow errors
- the chosen next transition is persisted and restored across resume

In practice, router outputs should be treated as structured outputs, not free-form prose.

## Example 5: Parallel Fan-Out

Use parallel execution when the same kind of work must be done across multiple branches.

```ruby
class FindingAgent < Smith::Agent
  register_as :finding_agent
  model "gpt-4.1-nano"
  budget token_limit: 8_000, cost: 0.20, wall_clock: 15
end

class ParallelResearchWorkflow < Smith::Workflow
  initial_state :idle
  state :done
  state :failed

  budget total_tokens: 60_000, total_cost: 1.50, wall_clock: 90

  transition :fan_out, from: :idle, to: :done do
    execute :finding_agent, parallel: true, count: 4
    on_failure :fail
  end
end
```

Why this is valuable:

- Smith treats each branch as a real invocation
- workflow budgets remain cumulative outer limits
- agent budgets still narrow each branch call
- branch failures discard step output and route through normal failure handling
- prepared input is reused consistently across branches

## Example 6: Nested Workflows

Use nested workflows when one part of the system deserves to be a reusable subflow with its own states and transitions.

```ruby
class ChildResearchAgent < Smith::Agent
  register_as :child_research_agent
  model "gpt-4.1-nano"
end

class ResearchSubflow < Smith::Workflow
  initial_state :idle
  state :done

  transition :research, from: :idle, to: :done do
    execute :child_research_agent
  end
end

class ParentWorkflow < Smith::Workflow
  initial_state :idle
  state :researched
  state :done
  state :failed

  transition :run_research, from: :idle, to: :researched do
    workflow ResearchSubflow
    on_failure :fail
  end

  transition :finish, from: :researched, to: :done
end
```

What you get:

- the child workflow's final output becomes the parent step output
- parent step count stays parent-scoped
- parent and child share the outer budget ledger
- nested best-known token/cost totals roll up into the parent result
- artifact scope is preserved across nesting

## Example 7: Evaluator-Optimizer

Use `optimize` when one agent generates candidates and another agent evaluates whether the result is acceptable.

The evaluator output is expected to carry a contract like:

- `accept: true/false`
- `feedback: ...` when rejecting
- optional `score`
- optional `converged`

Example:

```ruby
class TranslationEvaluationSchema
  # Replace this with your real RubyLLM schema object/class.
  # Intended shape:
  # { accept: true/false, feedback: "...", score: 0.93 }
end

class TranslationGenerator < Smith::Agent
  register_as :translation_generator
  model "gpt-4.1-nano"
end

class TranslationEvaluator < Smith::Agent
  register_as :translation_evaluator
  model "gpt-4.1-nano"
  output_schema TranslationEvaluationSchema
end

class TranslationWorkflow < Smith::Workflow
  initial_state :idle
  state :done
  state :failed

  transition :translate, from: :idle, to: :done do
    optimize generator: :translation_generator,
             evaluator: :translation_evaluator,
             max_rounds: 3,
             evaluator_schema: TranslationEvaluationSchema,
             improvement_threshold: 0.05
    on_failure :fail
  end
end
```

Why this matters:

- the loop is explicit, bounded, and observable
- acceptance criteria are structured
- exhaustion, malformed evaluator output, and convergence without acceptance fail normally
- costs and token usage from the full loop roll into the workflow totals

## Example 8: Orchestrator-Worker

Use `orchestrate` when you need an orchestrator that can emit structured tasks for workers and later decide when the system is done.

The orchestrator can emit one of:

- `tasks: [...]`
- `final: {...}`
- `stop: "...reason..."`

Example schemas:

```ruby
class ResearchTaskSchema
  def self.required_keys = %i[task_id input]
end

class WorkerOutputSchema
  def self.required_keys = %i[finding]
end

class FinalOutputSchema
  def self.required_keys = %i[summary]
end

class OrchestratorDecisionSchema
  # Replace this with your real RubyLLM schema object/class.
  # Intended shape:
  # { tasks: [...] } or { final: {...} } or { stop: "..." }
end
```

Example workflow:

```ruby
class ResearchOrchestrator < Smith::Agent
  register_as :research_orchestrator
  model "gpt-4.1-nano"
  output_schema OrchestratorDecisionSchema

  instructions do |_context|
    <<~TEXT
      Return exactly one of:
      - { tasks: [{ task_id:, input: }] }
      - { final: { summary: ... } }
      - { stop: "reason" }
    TEXT
  end
end

class ResearchWorker < Smith::Agent
  register_as :research_worker
  model "gpt-4.1-nano"
end

class ResearchProgramWorkflow < Smith::Workflow
  initial_state :idle
  state :done
  state :failed

  transition :research, from: :idle, to: :done do
    orchestrate orchestrator: :research_orchestrator,
                worker: :research_worker,
                max_workers: 4,
                max_delegation_rounds: 3,
                task_schema: ResearchTaskSchema,
                worker_output_schema: WorkerOutputSchema,
                final_output_schema: FinalOutputSchema
    on_failure :fail
  end
end
```

Why this is valuable:

- delegation is explicit and bounded
- tasks and outputs are structured
- worker fan-out is controlled
- exhaustion and malformed orchestrator output fail as first-class workflow failures

Notes:

- the workflow helper validates `task_schema`, `worker_output_schema`, and `final_output_schema`
- worker execution automatically applies `worker_output_schema`
- the orchestrator still benefits from `output_schema` so its decision shape is pushed down to the provider layer too

## Fallback Models

Fallback chains are declared on the agent and stay inside one logical invocation.

```ruby
class CriticalAgent < Smith::Agent
  register_as :critical_agent
  model "gpt-4.1"
  fallback_models "gpt-4.1-mini", "gpt-4.1-nano"
end
```

Current behavior:

- the primary model is tried first
- fallback moves through the declared chain
- only transient upstream failures trigger fallback
- guardrail, policy, schema, budget, deadline, and workflow failures do not
- best-known token and cost accounting accumulates across attempts
- the successful attempt is priced against the model that actually handled it

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

## Context, Session History, and Resume

Use `Smith::Context` when you want:

- persisted workflow context keys
- observation masking over session history
- injected state summaries

Example:

```ruby
class ReviewContext < Smith::Context
  persist :ticket_id, :current_findings, :source_urls

  session_strategy :observation_masking, window: 6

  inject_state do |persisted|
    <<~TEXT
      Ticket: #{persisted[:ticket_id]}
      Findings: #{persisted[:current_findings]}
      Sources: #{Array(persisted[:source_urls]).join(", ")}
    TEXT
  end
end

class ReviewWorkflow < Smith::Workflow
  context_manager ReviewContext
  initial_state :idle
  state :done

  transition :review, from: :idle, to: :done do
    execute :review_agent
  end
end
```

What Smith does for you:

- prepares masked session input at step boundaries
- injects a state summary message into that prepared input
- persists declared workflow context keys
- persists accepted session history
- preserves chosen next transitions across persistence
- supports JSON host round-trips through `to_state` and `.from_state`

Example host-controlled persistence:

```ruby
workflow = ReviewWorkflow.new(context: {
  ticket_id: "T-1042",
  current_findings: "needs escalation",
  source_urls: ["https://example.test/refund-policy"]
})

payload = JSON.generate(workflow.to_state)

# Store payload wherever your app wants.

restored = ReviewWorkflow.from_state(JSON.parse(payload))
result = restored.run!
```

Important: Smith is resumable, but it is still your app's job to store and retrieve that state.

For the common restore-or-initialize case, Smith also exposes a small configured-adapter one-liner:

```ruby
result = ReviewWorkflow.run_persisted!(
  key: "ticket:T-1042",
  context: {
    ticket_id: "T-1042",
    current_findings: "needs escalation"
  },
  on_step: ->(step) { puts "checkpointed #{step[:transition]}" },
  clear: :done
)
```

`clear: :done` is the default. Pass `clear: false` to preserve terminal state for host-managed cleanup timing, or `clear: :terminal` to clear any terminal workflow state once the run completes.

`on_step:` is a best-effort host callback. It runs after an accepted step has been checkpointed. Callback failures are logged and ignored; they do not roll back or abort durable workflow progression.

If the persistence key is a deterministic function of workflow context, declare it once on the workflow:

```ruby
class ReviewWorkflow < Smith::Workflow
  persistence_key { |ctx| "ticket:#{ctx[:ticket_id]}" }
end

result = ReviewWorkflow.run_persisted!(
  context: {
    ticket_id: "T-1042",
    current_findings: "needs escalation"
  }
)
```

When a workflow derives its key this way, Smith persists the resolved durability key in workflow state. That keeps instance-level helpers such as `persist!`, `advance_persisted!`, and `clear_persisted!` stable across restore even when the workflow's context manager persists only a filtered subset of context keys.

If you need more explicit control, the lower-level lifecycle is still available:

```ruby
workflow = ReviewWorkflow.restore_or_initialize(
  key: "ticket:T-1042",
  context: {
    ticket_id: "T-1042",
    current_findings: "needs escalation"
  }
)

step = workflow.advance_persisted!("ticket:T-1042")
# Host app can broadcast or project progress here.
emit_progress(step)

result = workflow.run_persisted!("ticket:T-1042")
workflow.clear_persisted!("ticket:T-1042")
```

`restore(key, ...)` is intentionally stricter: it requires a non-blank explicit key, and the lookup key remains authoritative for the restored workflow even if stored state contains an embedded `persistence_key`.

These helpers do not make Smith a job system or durable runtime. They only remove repetitive restore/checkpoint boilerplate around the configured persistence adapter while leaving queueing, projection, and recovery policy with the host app.

## Artifacts

Use artifacts when outputs are too large to keep inline.

Smith exposes:

- `Smith.artifacts.store`
- `Smith.artifacts.fetch`
- `Smith.artifacts.expired`

The common pattern is to hand off the heavy payload in `after_completion`.

```ruby
class LargeReportAgent < Smith::Agent
  register_as :large_report_agent
  model "gpt-4.1-nano"
  data_volume :unbounded

  def after_completion(result, _context)
    ref = Smith.artifacts.store(
      result[:full_report],
      content_type: "application/json"
    )

    {
      report_ref: ref,
      summary: result[:summary]
    }
  end
end
```

Configure a backend:

```ruby
Smith.configure do |config|
  config.artifact_store = Smith::Artifacts::Memory.new
  config.artifact_retention = 3600
end
```

Why this matters:

- large payloads can move out of the inline workflow result
- refs are execution-scoped
- nested workflows inherit artifact scope correctly

## Budgets, Deadlines, and Cost Tracking

Smith supports two budget layers.

Workflow budgets are cumulative outer limits:

```ruby
class BudgetedWorkflow < Smith::Workflow
  budget total_tokens: 100_000, total_cost: 3.00, wall_clock: 300, tool_calls: 20
end
```

Agent budgets are per-invocation narrowing constraints:

```ruby
class BudgetedAgent < Smith::Agent
  budget token_limit: 12_000, cost: 0.40, wall_clock: 20, tool_calls: 4
end
```

The naming is intentionally asymmetric:

- workflow budget dimensions are cumulative totals:
  - `total_tokens`
  - `total_cost`
- agent budget dimensions are per-invocation caps:
  - `token_limit`
  - `cost`

Shortcut:

- workflow budget means "how much can the whole workflow consume?"
- agent budget means "how much can this one invocation consume?"

Current budget model:

- workflow budgets are cumulative workflow truth
- agent budgets narrow individual invocations
- parallel branches honor per-branch agent budgets
- tool calls participate in budget enforcement
- denied tool calls do not leak exact `tool_calls` budget

Cost tracking is deliberately best-known:

- Smith computes model-call cost when pricing is configured
- unknown pricing does not fabricate cost
- unknown usage does not fabricate cost or tokens
- `RunResult.total_cost` and `total_tokens` are cumulative best-known totals
- totals include resumed execution, nested roll-up, and fallback attempts where usage is known

Example pricing configuration:

```ruby
Smith.configure do |config|
  config.pricing = {
    "gpt-4.1-nano" => {
      input_cost_per_token: 0.0000001,
      output_cost_per_token: 0.0000004
    }
  }
end
```

## Tracing

Smith can emit structural traces for:

- transitions
- tool calls
- token usage
- cost

Example:

```ruby
Smith.configure do |config|
  config.trace_adapter = Smith::Trace::Logger
  config.trace_transitions = true
  config.trace_tool_calls = true
  config.trace_token_usage = true
  config.trace_cost = true
  config.trace_content = false
end
```

Built-in adapters include:

- `Smith::Trace::Memory`
- `Smith::Trace::Logger`
- `Smith::Trace::OpenTelemetry`

The default posture is structural tracing with content omitted unless you opt in.

## Configuration

There are three different configuration scopes.

### 1. Global runtime configuration: `Smith.configure`

Use this for shared runtime services:

- artifact backend
- tracing
- pricing catalog
- logger

### 2. Agent configuration: `Smith::Agent`

Use agent classes for invocation behavior:

- `model`
- `tools`
- `instructions`
- `temperature`
- `thinking`
- `budget`
- `guardrails`
- `output_schema`
- `data_volume`
- `fallback_models`
- `register_as`

### 3. Workflow configuration: `Smith::Workflow`

Use workflow classes for orchestration behavior:

- `initial_state`
- `state`
- `transition`
- `pipeline`
- `budget`
- `max_transitions`
- `guardrails`
- `context_manager`

### If You Are Unsure Where Something Goes

- "Which model should this agent use?" -> agent class
- "How do I store artifacts or emit traces?" -> `Smith.configure`
- "What happens after this step succeeds or fails?" -> workflow class
- "How many tokens/cost/tool calls can this one invocation use?" -> agent budget
- "How much total budget can the whole workflow consume?" -> workflow budget
- "Which provider credentials should the app use?" -> RubyLLM, not Smith

### Full `Smith.configure` Example

```ruby
Smith.configure do |config|
  config.artifact_store = Smith::Artifacts::Memory.new
  config.artifact_retention = 3600
  config.artifact_encryption = :none
  config.artifact_tenant_isolation = false

  config.trace_adapter = Smith::Trace::Logger
  config.trace_transitions = true
  config.trace_tool_calls = true
  config.trace_token_usage = true
  config.trace_cost = true
  config.trace_fields = {
    transition: %i[transition from to],
    tool_call: %i[tool duration]
  }
  config.trace_content = false
  config.trace_retention = 86_400
  config.trace_tenant_isolation = false

  config.pricing = {
    "gpt-4.1-nano" => {
      input_cost_per_token: 0.0000001,
      output_cost_per_token: 0.0000004
    }
  }

  config.logger = Logger.new($stdout)
end
```

### What Each `Smith.configure` Setting Is For

| Setting | What it controls | Typical first use |
| --- | --- | --- |
| `artifact_store` | Where large handoff payloads are stored | Start with `Smith::Artifacts::Memory.new` |
| `artifact_retention` | Default retention window for artifact expiry checks | Set once you have a cleanup policy |
| `artifact_encryption` | Metadata-level encryption policy flag | Leave at default until you wire a real backend |
| `artifact_tenant_isolation` | Require namespaced artifact writes | Enable in multi-tenant systems |
| `trace_adapter` | Where structural traces go | Use `Smith::Trace::Memory` or `Smith::Trace::Logger` first |
| `trace_transitions` | Emit transition traces | Usually leave on |
| `trace_tool_calls` | Emit tool call traces | Usually leave on |
| `trace_token_usage` | Emit usage traces | Useful for budget visibility |
| `trace_cost` | Emit cost traces | Useful once pricing is configured |
| `trace_fields` | Allowlist structural trace fields | Use when you want tighter trace output |
| `trace_content` | Whether content appears in traces | Leave `false` first |
| `trace_retention` | Trace retention policy hook | Useful when traces leave memory |
| `trace_tenant_isolation` | Trace multi-tenant isolation flag | Enable in multi-tenant systems |
| `pricing` | Best-known model-call cost catalog | Add once you care about `total_cost` |
| `logger` | Smith's runtime logger | Usually the first setting to add |

### Recommended First Additions

Add settings in this order:

1. `config.logger`
2. `config.trace_adapter`
3. `config.artifact_store`
4. `config.pricing`

Do not start by configuring every advanced switch at once.

## Development Notes

If you are evaluating Smith seriously before release:

- treat this README as a guide, not a frozen contract
- pin the exact commit you depend on
- check [`spec/SPEC_MATRIX.md`](./spec/SPEC_MATRIX.md) for what is directly covered
- verify the specific runtime seam you care about in the specs

The project is already useful for exploring workflow-first agent design, but the public surface is still settling.

## Running The Project Locally

```bash
bundle install
bundle exec rspec
```

## Summary

Smith is for Ruby teams that want agent systems with:

- explicit orchestration
- composable multi-agent patterns
- real budgets and guardrails
- resumable workflow state
- artifacts and tracing
- enough structure to build serious applications without pretending prompts are control flow

If that is the layer you need, Smith is the interesting part of the stack.
