# Smith

Workflow-first multi-agent orchestration for Ruby. Smith sits on top of `RubyLLM` and adds explicit state machines, typed contracts, budgets, guardrails, persistence, tools, and tracing for production agent systems.

> [!WARNING]
> Smith is pre-1.0. Expect contract tightening between minor versions. Pin to an exact version in production.

## Verification Discipline

Tests are required, but they are never enough for runtime primitive changes.
Every Smith workflow slice must also run practical gem-level execution probes.
When a host application consumes unreleased Smith changes, point that host app at
the local Smith repository and exercise the changed workflow paths in the host
environment before calling the slice complete.

## Installation

```ruby
# Gemfile
gem "smith-agents", "~> 0.4.3", require: "smith"
```

```bash
bundle install
```

The Ruby module namespace stays `Smith::`; only the gem name is namespaced because `smith` on RubyGems is taken. The `require: "smith"` in the Gemfile tells bundler to load the actual file name.

## Quickstart

```ruby
require "ruby_llm"
require "smith"

RubyLLM.configure do |config|
  config.openai_api_key = ENV.fetch("OPENAI_API_KEY")
end

class ReplyAgent < Smith::Agent
  register_as :reply_agent
  model "gpt-4.1-nano"

  instructions { "Write a concise, professional reply." }
end

class ReplyContext < Smith::Context
  persist :user_message
  inject_state { |p| "User message: #{p[:user_message]}" }
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

result = ReplyWorkflow.new(context: { user_message: "Charged twice." }).run!
result.state    # => :done
result.output   # => assistant reply
result.steps    # => [{ transition: :reply, from: :idle, to: :done, output: ... }]
```

## Core Concepts

| Concept | Purpose |
|---|---|
| `Smith::Agent` | A `RubyLLM` agent plus model, instructions, output schema, tools, budget, and fallback models. Identifies itself to the workflow via `register_as :name`. |
| `Smith::Workflow` | A state machine of named transitions. Each transition calls an agent, runs deterministic code, routes, or composes a nested workflow. |
| `Smith::Context` | Declares which workflow context keys persist across restore, and how those keys become agent-visible input via `inject_state`. |
| `Smith::Tool` | A `RubyLLM` tool plus provider-compatibility metadata and guardrail hooks. |
| Persistence adapters | Host-owned storage. Smith ships `Memory`, `RedisStore`, `CacheStore`, `RailsCache`, `ActiveRecordStore`. |
| Trace adapters | Host-owned observability. Smith ships `Memory`, `Logger`, `OpenTelemetry`. |

Agents register at class load. In Rails, register workflow-facing agents in a `to_prepare` hook so autoload doesn't drop them:

```ruby
# config/initializers/smith_agents.rb
Rails.application.config.to_prepare do
  ReplyAgent
  TriageAgent
end
```

## Patterns

| Pattern | DSL | Use case |
|---|---|---|
| Single execute | `execute :agent` | One agent call per transition. |
| Pipeline | sequential transitions | Multi-step workflow with explicit success/failure routing. |
| Router | `route :classifier, routes: {...}` | Branch on a classifier agent's output. |
| Parallel fan-out | `execute :agent, parallel: true` | Concurrent agent calls under one ledger. |
| Heterogeneous fan-out | `fan_out branches: {...}` | Concurrent calls to different agents with named branch results. |
| Nested workflow | `workflow OtherWorkflow` | Reuse a subflow as one transition. |
| Evaluator-Optimizer | `optimize generator:, evaluator:, ...` | Generate-then-critique refinement loops. |
| Orchestrator-Worker | `orchestrate orchestrator:, worker:, ...` | Dynamic task fan-out with delegation rounds. |
| Deterministic | `compute { |step| ... }` | Pure Ruby step inside the state machine. |

The full pattern guide with working examples for each lives in [`docs/PATTERNS.md`](docs/PATTERNS.md).

### Repair And Wait Boundaries

Smith only owns repair and wait-style loop behavior when the bounds and stop
conditions are explicit and enforceable inside the workflow step. Durable
timers, queue delivery, and wake-up policy remain host-owned.
For bounded dynamic delegation, use the separate Orchestrator-Worker pattern.

| Contract | Status | Smith mapping |
|---|---|---|
| Retry loop | Executable | `retry_on`, bounded to one transition. |
| Evaluator-Optimizer | Executable | `optimize`, bounded by `max_rounds` plus structured evaluator output. |
| Deterministic repair | Not first-class yet | Can be handwritten with `compute` / `run` only when the workflow author owns the exact guard, repair, revalidation, and exit policy. Deterministic steps may declare inspectable `routes: [...]`, but that is not a native repair-loop contract. |
| Guarded state re-entry | Not first-class yet | `compute` / `run` can declare and route to named transitions with `routes: [...]`, but Smith does not yet own persisted entry counts, mutation policy, or safe re-entry contracts. |
| Polling / wait | Host-owned | Use the host app's queue/timer plus Smith persistence helpers. Smith must not model durable polling with busy-waits or sleep loops. |

## Workflow Graph Inspection

Smith can inspect a workflow's declared graph without running agents or advancing state. This is useful for host apps that want to render, lint, or cache a workflow shape before execution.

```ruby
report = ReplyWorkflow.validate_graph

report.valid?        # => true
report.transitions   # => read-only transition snapshots
report.diagnostics   # => errors and warnings for missing states or routes
report.metrics       # => state, transition, reachability, and terminal-state counts
```

Graph inspection is static and diagnostic-only. Runtime execution, persistence, progress projection, retries, and recovery remain host-owned concerns.

Smith also exposes a static runtime-readiness report for checks that require
declared runtime bindings but still do not execute the workflow:

```ruby
readiness = ReplyWorkflow.runtime_readiness

readiness.ready?       # => true when no readiness/topology errors exist
readiness.status       # => :ready, :warning, or :not_ready
readiness.diagnostics  # => topology diagnostics + runtime binding diagnostics
```

Runtime readiness checks graph topology, registered agent bindings, model
requirements for structured runtime roles, lazy/uninspectable bindings, invalid
non-agent bindings, nested workflow readiness, and fan-out branch binding counts.
It does not call providers, resolve lazy container blocks, run tools, enqueue
jobs, or verify host-owned durability.

Readiness metrics include both direct graph counts and transitive counts folded
in from nested workflows.

Transition snapshots include runtime contracts for complex primitives where
Smith owns executable semantics: heterogeneous fan-out, evaluator-optimizer, and
orchestrator-worker transitions expose bounded settings, output shapes, and
transition-level resume behavior for host renderers and compilers.

## Configuration

```ruby
require "logger"
require "smith"

Smith.configure do |config|
  config.logger = Logger.new($stdout)
  config.trace_adapter = Smith::Trace::Memory.new
  config.artifact_store = Smith::Artifacts::Memory.new

  # Persistence
  config.persistence_adapter = :rails_cache
  config.persistence_options = { namespace: "smith" }
  config.persistence_ttl = 1.day.to_i
  config.persistence_retry_policy = { attempts: 3, base_delay: 0.1, max_delay: 1.0 }

  # OpenAI /v1/responses routing for gpt-5 + tools + thinking. :auto (default) or :off.
  config.openai_api_mode = :auto

  config.pricing = {
    "gpt-4.1-nano" => { input_cost_per_token: 1.0e-7, output_cost_per_token: 4.0e-7 }
  }
end
```

All settings are optional for a first run. See [`docs/CONFIGURATION.md`](docs/CONFIGURATION.md) for the full reference.

## Persistence and Resume

```ruby
# Persist after every advance
result = ReplyWorkflow.run_persisted!(
  context: { user_message: "..." },
  adapter: Smith.persistence_adapter
)

# Resume later
result = ReplyWorkflow.run_persisted!(
  key: "ticket:T-1042",
  adapter: Smith.persistence_adapter
)
```

Built-in adapters (all support TTL where the backend allows; `Redis`,
`ActiveRecord`, and `Memory` support optimistic locking via `store_versioned`;
`Redis` and `Memory` also support heartbeat probes via `record_heartbeat` /
`last_heartbeat`):

- `:memory` — in-process Hash, intended for tests and `test_mode = true`
- `:redis` — Redis client; uses WATCH/MULTI/EXEC for CAS
- `:rails_cache`, `:solid_cache` — Rails cache backends
- `:cache_store` — any object responding to `write/read/delete`
- `:active_record` — keyed ActiveRecord model with `lock_version` column for CAS

See [`docs/PERSISTENCE.md`](docs/PERSISTENCE.md) for schema versioning, seed-drift validation, and the `idempotency_mode :strict` step-in-progress contract.

## Tools and Guardrails

Smith ships `Tools::WebSearch`, `Tools::UrlFetcher`, and `Tools::Think`. Tools declare provider compatibility via `compatible_with`; Smith's normalizer routes or drops them per-attempt.

```ruby
class SearchAgent < Smith::Agent
  register_as :search_agent
  model "claude-opus-4-7"
  tools Smith::Tools::WebSearch, Smith::Tools::UrlFetcher
end
```

Guardrails run as input/output gates around agent calls. See [`docs/TOOLS_AND_GUARDRAILS.md`](docs/TOOLS_AND_GUARDRAILS.md).

## Budgets and Deadlines

```ruby
class BudgetedWorkflow < Smith::Workflow
  budget total_tokens: 10_000, total_cost: 0.50, wall_clock_ms: 30_000
end
```

Budgets reserve serially at each step and reconcile after the agent call. Parallel branches reserve scoped envelopes that release back to the parent ledger. The `Workflow::RunResult` carries `total_tokens`, `total_cost`, and per-call `usage_entries`.

## Doctor

After adding Smith, verify the integration:

```bash
# Plain Ruby
smith doctor              # offline checks
smith doctor --live       # live provider call
smith doctor --durability # persistence round-trip
smith install             # scaffold config/smith.rb

# Rails
bin/rails smith:doctor
bin/rails smith:doctor:live
bin/rails smith:doctor:durability
bin/rails generate smith:install
```

Doctor verifies: Smith loads, RubyLLM loads, minimal workflow boots, configuration is non-empty, serialization round-trips, persistence adapter works, and (with `--live`) a real provider call succeeds.

## Capability-aware request shaping

Smith ships a per-attempt normalizer that translates the request payload to whatever the resolved model's provider family expects:

- Anthropic Opus 4.7+ adaptive thinking via `output_config[:effort]`
- Anthropic 4.0–4.6 budget_tokens
- OpenAI gpt-5 family reasoning_effort with `/v1/responses` routing when tools + thinking are combined
- Gemini 2.5+ budget_tokens

Override the inferred profile per-app via `Smith::Models.register(Profile.new(...))`. Hosts pin to specific model_ids by registering profiles; Smith never hardcodes model_ids in the library.

## Errors and retry

```ruby
Smith::Errors.retryable?(error)
# AgentError, DeadlineExceeded => true (always)
# DeterministicStepFailure, ToolGuardrailFailed => honors error.retryable
# everything else => false

Smith::Errors.retryable_classes
# => [Smith::AgentError, Smith::DeadlineExceeded]  (for ActiveJob retry_on)
```

Workflow transitions can also declare a bounded local retry policy:

```ruby
transition :draft, from: :idle, to: :done do
  execute :writer
  retry_on Smith::AgentError, attempts: 3, backoff: 0.1, max_delay: 1.0
end
```

When no classes are passed, `retry_on` uses `Smith::Errors.retryable?`.
This is a bounded local transition retry policy. Durable scheduling, long waits,
and external idempotency guarantees remain host-owned.

## Development

```bash
bundle install
bundle exec rspec
bundle exec rubocop
```

880 examples, MIT licensed. See [`CHANGELOG.md`](CHANGELOG.md) for the current
release surface.
