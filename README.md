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
gem "smith-agents", "0.5.0", require: "smith"
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
| `Smith::Context` | Declares which workflow context keys persist across restore, how those keys become agent-visible input via `inject_state`, and which keys hold untrusted outside content (`untrusted`). |
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
| Wait | `await :event, into:, timeout:` / `delay seconds` | Durable wait for an event the host delivers, or until a time. |

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
| Wait for an event or a time | Executable | `await` and `delay`, bounded by a required timeout and timeout route. Smith records the wait and its deadline; delivering the event (`resume!`), scheduling the expiry (`expire_wait!`) and waking the run stay host-owned. Smith never polls for an event or sleeps until a deadline. |

### Isolation

Each agent step can get its own messages and write its output to the context
instead of a shared transcript:

```ruby
class ReviewContext < Smith::Context
  persist :source, :fields
  untrusted :source, :fields   # outside text, and what an agent drew from it
end

class DocumentReview < Smith::Workflow
  context_manager ReviewContext
  session :isolated   # no shared transcript; every agent step declares input:
  initial_state :fetched
  state :extracted

  transition :extract, from: :fetched, to: :extracted do
    execute :field_extractor,
            input: ->(ctx) { [{ role: :user, content: Smith::Untrusted.wrap(ctx[:source], source: "document") }] },
            output_to: :fields
  end
end
```

Context keys declared `untrusted` never reach `inject_state`, the
`seed_messages` builder, or an agent's `inputs`, in the workflow or any
workflow it nests. See [`docs/PERSISTENCE.md`](docs/PERSISTENCE.md), Step
Isolation and Untrusted Content.

### Waiting

A step can wait, durably and bounded, for an event the host delivers or for a
time to pass:

```ruby
class DocumentReview < Smith::Workflow
  initial_state :requested

  transition :fetch_source, from: :requested, to: :fetched do
    await :source_ready, into: :source, timeout: 6 * 3600 do |step|
      SourceClient.request(ref: step.read_context(:source_ref), idempotency_key: step.await_token)
    end
    on_timeout :source_unavailable
  end
  transition :source_unavailable, from: :requested, to: :unavailable

  transition(:cool_off, from: :fetched, to: :reviewed) { delay 600 }
end

workflow.run_persisted!(key)       # stops when the run waits
workflow.waiting?                  # => true
workflow.awaiting                  # => Smith::Workflow::Wait (event, token, deadline_at, ...)

DocumentReview.resume!(key, event: :source_ready, token:, payload: reply)  # => :resumed, :failed, :missing or :stale
DocumentReview.expire_wait!(key, token:, now: Time.now.utc)                # => :expired, :not_due, :missing or :stale
```

The host indexes `awaiting` to route events and to schedule the expiry call.
See [`docs/PERSISTENCE.md`](docs/PERSISTENCE.md), Waiting.

### Child runs

A step can start other workflows as runs of their own, which the host launches,
persists and runs, and wait for their results:

```ruby
Smith.config.run_launcher = MyLauncher.new   # launch(children:, parent_key:, await_token:)

class DocumentReview < Smith::Workflow
  initial_state :split
  state :failed

  transition :review_sections, from: :split, to: :reviewed do
    map :section_ids, workflow: SectionReview, max_items: 500, timeout: 6 * 3600,
        input: ->(section_id, ctx) { { document_id: ctx[:document_id], section_id: } },
        into: :section_reviews, collect: :outputs, on_item_failure: :collect
    on_failure :fail
  end

  transition :summarize, from: :reviewed, to: :summarized do
    call Summarize, input: ->(ctx) { { document_id: ctx[:document_id] } }, timeout: 3600, into: :summary
    on_failure :fail
  end

  transition :notify, from: :summarized, to: :done do
    spawn :watcher_ids, workflow: NotifyWatcher, max_items: 1_000, input: ->(id, _ctx) { { watcher_id: id } }
  end
end
```

`map` launches a run per item (more than `max_items` fails the step before
anything launches; the launcher is idempotent on each child's `key`) and waits,
bounded by `timeout:`, for the host to resume the parent with
`resume!(key, event: :children, token:, payload:)`, one `Smith::ChildRun.result`
entry per child. `call` is a map of one whose `into:`
gets the child's output; `spawn` launches and continues. A child starts with
only what `input:` returns, and keeps any of its parent's untrusted keys passed
under the same name. With `on_item_failure: :fail` (the default) a failed child
fails the step with `Smith::ChildRunsFailed`, so the step declares `on_failure`;
these steps take no `retry_on`. `Smith::Launchers::Inline` runs the children in
process, for tests and scripts. See
[`docs/PERSISTENCE.md`](docs/PERSISTENCE.md), Child Runs.

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

  # Generic runtime resource bounds
  config.parallel_branch_limit = 1_000
  config.parallel_concurrency = 8
  config.parallel_nesting_limit = 64
  config.retry_attempt_limit = 100

  # OpenAI /v1/responses routing for gpt-5 + tools + thinking. :auto (default) or :off.
  config.openai_api_mode = :auto

  config.pricing = Smith::Pricing.validate_catalog!(
    %w[openai gpt-4.1-nano] => {
      input_cost_per_token: 1.0e-7, output_cost_per_token: 4.0e-7,
      cache_read_cost_per_token: 2.5e-8, # optional: prompt-cache reads (0 when absent)
      batch_discount: 0.5                # optional: off the cost of batch-mode calls (0 when absent; batch steps arrive later in 0.12)
    }
  )
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

# Admit host-supplied conversation input at a stable workflow boundary.
workflow = ReplyWorkflow.restore("ticket:T-1042", adapter: Smith.persistence_adapter)
admission = workflow.append_session_messages!(role: :user, content: "Continue")
```

`append_session_messages!` validates and owns a bounded canonical copy of the
message batch, appends it under Smith's workflow lifecycle lock, and returns an
immutable digest witness. The host still owns session identity, transaction
coordination, persistence, idempotency, and resume policy.

Built-in adapters (all except `ActiveRecord` support TTL; `ActiveRecord` has no
expiry column, so its writes refuse a non-nil `persistence_ttl`, while reads and
deletes keep working and `smith doctor --durability` flags the combination;
`Redis`, `ActiveRecord`, and `Memory` support optimistic locking via
`store_versioned` and exact dispatch claims via `replace_exact`; `ActiveRecord`
participates in the caller's transaction for host-record coordination;
`Redis` and `Memory` also support heartbeat probes via `record_heartbeat` /
`last_heartbeat`):

- `:memory` — in-process Hash, intended for tests and `test_mode = true`
- `:redis` — Redis client; uses WATCH/MULTI/EXEC for CAS
- `:rails_cache`, `:solid_cache` — Rails cache backends
- `:cache_store` — any object responding to `write/read/delete`
- `:active_record` — keyed ActiveRecord model with an enabled optimistic-locking
  column for row-level CAS; Smith's logical version remains in the JSON payload

See [`docs/PERSISTENCE.md`](docs/PERSISTENCE.md) for schema versioning,
seed-drift validation, the `idempotency_mode :strict` step-in-progress contract,
host-coordinated message admission, and opt-in restart-safe prepared recovery.
Hosts that need to commit a durable attempt before provider or tool work can
separate verification from execution with
`authorize_prepared_step_execution!`, commit their own attempt ledger, and then
consume the exact process-local capability through
`execute_authorized_prepared_step!`. Smith does not own the host lease, attempt
record, scheduler, or unknown-outcome policy. Authorization discovers the exact
agent bindings reachable by that transition with a bounded `O(V + E)` graph
walk, then resolves the bounded binding set in one registry epoch. A concurrent
registry writer therefore cannot produce a mixed authorization containing
bindings from two registry states or replace a captured binding between
authorization and work. Every public Dry::Container mutation path participates
in that epoch. Execution authorization accepts only concrete registered
`Smith::Agent` classes; lazy container callbacks are not executed while
authority is captured.
While the capability is active, a host may call `each_agent_binding` with a
block to inspect the exact captured `(registry_name, agent_class)` pairs before
external work. Enumeration is process-local, performs no dispatch, and is
rejected after release or consumption; it deliberately does not return a lazy
enumerator that could escape the authorization scope.
Reachable nested workflow transition contracts are captured and revalidated
before child execution. The typed result owns a bounded snapshot of JSON-like
Ruby values; unsupported mutable output values fail closed.
During authorized execution, Smith also seals its private execution path against
workflow subclass method-name collisions, including nested child workflows.
Ordinary non-authorized runs retain normal Ruby override behavior.

For `parallel: true` and `fan_out` transitions, a host can split one confirmed
dispatch into independently scheduled branch operations without invoking agent
classes outside Smith:

```ruby
preparation = workflow.prepare_composite_step!

# Persist preparation.plan and preparation.input in host-owned records.
# Each worker recovers the same confirmed dispatch and receives one descriptor.
branch = preparation.plan.branches.fetch(0)
execution = preparation.plan.execution_for(branch)
outcome = branch_workflow.execute_prepared_composite_branch!(
  execution:,
  input: preparation.input
)

# After every branch has a terminal outcome, use another fresh recovery to
# complete the Smith transition exactly once.
result = reducer_workflow.reduce_prepared_composite_step!(
  plan: preparation.plan,
  input: preparation.input,
  outcomes: ordered_or_unordered_complete_outcome_set,
  primary_failure: host_committed_failed_branch_key
)
```

Plans bind the exact prepared dispatch, host-supplied complete workflow
`definition_digest`, execution-semantics version, prepared input digest, budget
baseline, one shared artifact execution namespace, ordered branch identities,
and explicit policies. Each plan, input, outcome, or effect payload is
canonical, immutable, bounded to 1 MiB after JSON encoding, rejects missing or
unknown fields, and redacts exception messages and backtraces.
Reduction additionally bounds cumulative effects to 1 MiB and final aggregate
output to 4 MiB before consuming execution authority. Reduction accepts either
an `Array` or an `Enumerator`, validates each outcome incrementally, and stops
as soon as a cumulative bound is crossed. The transport hard limit is 10,000
branches; every recovered worker also enforces the current
`Smith.config.parallel_branch_limit` before work.

Planning is `O(B * D)`, where `D` is the bounded number of budget dimensions.
The coordinator derives a compact selected-branch execution envelope in
`O(D)` without copying the full branch collection. The scoped branch execution
entry point captures and validates one selected binding in `O(D)` and constant
time with respect to total branch count; the reducer validates the complete plan
once. Reduction is `O(B + P log P)` in
the worst case because canonical nested Hash ownership sorts keys, and uses
`O(B + P)` bounded space.
Smith does not persist plans or outcomes, select scheduling slots, claim work,
choose an uncertain-outcome policy, or infer the primary failure. The host
durably owns those decisions, gives each branch and reduction a separately
recovered workflow instance, and must pass a complete outcome set. Transport or
encoding faults become typed branch failures when Smith can preserve accounting
evidence; otherwise the host must treat the worker result as uncertain and must
not infer safe retry. Resume policy is incomplete branches only; per-branch
retry is intentionally unsupported in this contract version.
Composite payload digests prove canonical content integrity, not worker
authenticity. Before reduction, the host must authenticate every outcome against
its own claimed operation identity and current fencing token; those durable
receipts remain outside Smith.

The supported composite API is the three scoped workflow methods above plus the
immutable transport values they return or accept: `Preparation`, `Plan`,
`Input`, `Branch`, `BranchExecution`, `BranchOutcome`, `BranchFailure`, `Error`,
`Effects`, and `Reduction`. Other constants under `Workflow::Composite` are
implementation collaborators, not extension points or compatibility promises.

Every agent used by this durable composite boundary must declare a stable
host-computed SHA-256 execution identity. The identity represents the exact
sealed executable asset the host intends to dispatch; Smith records it in the
branch descriptor and rejects registry replacement after planning. Identities
are deliberately not inherited because a subclass is a distinct executable
implementation.

```ruby
class Researcher < Smith::Agent
  execution_identity Digest::SHA256.hexdigest(generated_asset_manifest)
  register_as :researcher, publish: false
end

Researcher.freeze
Researcher.publish_registration!
```

Hosts that generate agent classes dynamically may call
`register_as :name, publish: false` while constructing the class. This records
the class identity without exposing it through `Smith::Agent::Registry`. After
the host has validated and sealed the class, it may publish the exact class with
`agent_class.publish_registration!`. Publication always uses the staged,
immutable identity; callers cannot provide a second key. Registry collision and
mutation epoch guarantees remain unchanged.

Hosts that persist or cache generated executable definitions should include
`Smith::EXECUTION_SEMANTICS_VERSION` in their definition identity. The gem
version describes the package release; the execution-semantics version changes
when Smith's executable workflow contract changes and must participate in host
cache invalidation.

## Tools and Guardrails

Smith ships `Tools::WebSearch`, `Tools::UrlFetcher`, and `Tools::Think`. Tools declare provider compatibility via `compatible_with`; Smith's normalizer routes or drops them per-attempt.

```ruby
class SearchAgent < Smith::Agent
  register_as :search_agent
  model "claude-opus-4-7"
  tools Smith::Tools::WebSearch, Smith::Tools::UrlFetcher
  budget tool_calls: 3
  tool_budget_exhaustion :complete
end
```

Agent tool-call budgets default to raising `Smith::BudgetExceeded` when a tool
tries to execute beyond the configured limit. Agents that declare
`tool_budget_exhaustion :complete` must also declare a finite `tool_calls`
budget. Smith then consumes each model-requested call before dispatch, executes
only a complete batch admitted against both agent and workflow limits, and
performs one tool-disabled completion when the allowance is exhausted or the
provider returns an oversized batch. The bounded provider loop is iterative,
not recursive. Calls to unavailable tools consume allowance as well, so a
provider cannot create an unbounded correction loop. Workflow reservations are
reconciled to actual Smith tool execution.

Hosts may install `Smith::Tool::CallBudget` with exact per-tool limits through
`Smith::Tool.with_call_budget`. Smith propagates that same root allowance into
parallel and heterogeneous fan-out worker threads; agent budgets narrow the
root and all branches share its atomic counters.

Graceful exhaustion is an in-process protocol guarantee, not durable recovery
for the model/tool loop. If the process exits after a tool begins and before the
agent completes, the host must treat the outcome as uncertain unless it owns a
durable per-invocation receipt and reconciliation contract. Smith also refuses
to start a fresh fallback-model chat after tool execution has begun because that
would discard the captured evidence and conversation protocol.

Within a host invocation scope, `Smith::Tool.current_invocation` exposes the
normalized tool-call ID and deterministic execution/batch ordinals. The ID is
RubyLLM correlation metadata and must not be treated as a provider idempotency
key. Durable hosts can pass an explicitly seeded
`Smith::Tool::InvocationSequence` to `with_invocation_context`; Smith itself does
not persist or reconcile operation receipts.

Guardrails run as input/output gates around agent calls. See [`docs/TOOLS_AND_GUARDRAILS.md`](docs/TOOLS_AND_GUARDRAILS.md).

## Budgets and Deadlines

```ruby
class BudgetedWorkflow < Smith::Workflow
  budget total_tokens: 10_000, total_cost: 0.50, wall_clock: 30
end
```

`wall_clock` is in seconds. A workflow's `wall_clock` bounds the time its steps
spend running, counted across restores in the persisted `active_seconds`, not
the time since the run was created: time spent waiting, or between steps a host
advances from a queue, does not count. A step that raised or whose process died
is charged, on the next restore, the time from its start, at most what is left
of the budget, so a run that keeps failing stays bounded across retries.
Durable composite branches each start from what is left; their running time is
not added back. An agent's `wall_clock` bounds each of
its calls. A workflow budget accepts `total_tokens`,
`token_limit`, `total_cost`, `tool_calls`, and `wall_clock`; an agent budget
accepts `token_limit`, `cost`, `wall_clock`, `tool_calls`, `total_tokens`, and
`total_cost`. Any other key raises `ArgumentError` naming the accepted keys. A
restored run drops consumed amounts for keys the workflow no longer declares.

Budgets reserve serially at each step and reconcile after the agent call. Parallel branches reserve scoped envelopes that release back to the parent ledger. The `Workflow::RunResult` carries `total_tokens`, `total_cost`, and per-call `usage_entries`. Token budgets and totals count prompt-cache reads and writes beside uncached input and output, and settle every billed response, including the completed rounds of a tool loop whose attempt then failed.

Direct ledger integrations settle the exact receipt returned by reservation:

```ruby
reservation = ledger.reserve_many!(total_tokens: 1_000, total_cost: 0.10)
ledger.reconcile_many!(reservation, actual: { total_tokens: 640, total_cost: 0.06 })
```

`release!` / `release_many!` accept the same receipt when work never starts.
Receipts are ledger-owned and one-shot: another ledger, a replay, or an
amount-only settlement is rejected. `ledger.remaining(key)` never reads back
above the exact remaining amount, and `ledger.remaining_share(key, parts)`
returns one of `parts` equal shares of it such that reserving all `parts` fits.

Budget amounts accept finite, non-negative `Integer` and `Float` values. Smith
uses an exact `BigDecimal` representation derived from each value's canonical
decimal text and converts ledger snapshots back to ordinary JSON-safe numerics,
avoiding cumulative binary Float drift without changing persisted workflow
state shapes. Ledger arithmetic temporarily uses unlimited decimal precision and
restores the host's existing `BigDecimal` precision limit before returning.

Budget operations are atomic for normal concurrent callers and synchronous
exceptions. Smith uses cooperative cancellation and never terminates branch
threads with `Thread#raise` or `Thread#kill`. Arbitrary asynchronous thread
termination can make any in-process return value outcome-ambiguous; hosts must
use cancellation signals, bounded I/O, and process isolation for hard stops.

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

Override the inferred profile per-app via `Smith::Models.register(Profile.new(...))`.
Profiles are keyed by both provider and model id. Pass `provider:` to
`Smith::Models.find` or `find_or_infer` whenever an id exists under more than
one provider; an ambiguous unqualified lookup fails closed. Smith never
hardcodes model ids in the library.

Provider-qualified fallback entries use the same exact identity:

```ruby
fallback_models(
  { model: "claude-sonnet-4-6", provider: :anthropic },
  { model: "openai/gpt-5", provider: :openrouter }
)
```

Fallback entries must include an explicit provider. Smith does not infer a
fallback provider from the primary model or from a model id because the same id
may be registered by more than one provider. Unqualified fallback entries fail
closed during agent configuration.

## Agent outputs

Smith reads how each response ended from the provider's stop reason. A
response cut off at its output limit, a refused one, and a structured output
that is not what the agent declares are not accepted as the step's output:

```ruby
class Reviewer < Smith::Agent
  model "claude-opus-5-5", provider: :anthropic
  output_schema ReviewSchema                         # its root is an object
  output_contract ReviewContract                     # call(hash) => true, false, or a result with success? and errors
  output_repairs 1                                   # the default; 0 turns repair off
  on_truncation retry_with: { max_tokens: 64_000 }   # or :fail (the default), or :accept
  on_refusal fallback: "openai/gpt-5"                # or :fail (the default)
end
```

- A cut-off response raises `Smith::OutputTruncated`, unless the agent
  accepts it or retries it once on the same model with a larger output limit,
  mapped to the provider's own parameter (Anthropic, OpenAI, Gemini, Vertex AI
  and Bedrock; another provider is not retried). There is no retry when the
  response ran out of context rather than output, or when the new limit is no
  larger than the request had (the agent's own parameter, or for Anthropic the
  model's maximum, which RubyLLM already sends); a later repair keeps the
  larger limit.
- A refused response (a Gemini prompt block included) raises
  `Smith::OutputRefused`, unless the agent falls back once to another model.
- Every other response then goes through the agent's `after_completion`. A
  structured output (an `output_schema`, or a static RubyLLM `schema`) that is
  not a JSON object, breaks a schema constraint, or fails the output contract
  goes back to the same model up to `output_repairs` times: the step's messages
  as the provider got them, the rejected reply as the assistant's, and the
  problems as "path: problem" lines. It then raises `Smith::OutputInvalid`,
  whose `problems` lists at most 20 of them. A blank output still raises
  `Smith::BlankAgentOutputError`.
- No follow-up call is made once a tool has run in the step (the tools would
  run again; the step fails with `Smith::ToolOutcomeUncertain` around the output
  error) or once the call has spent what its step reserved from a budget. A
  follow-up that fails raises the output error it was making up for, with the
  provider's error as its cause.
- Anthropic's structured outputs reject numeric, string-length and most
  array-size constraints: Smith sends Anthropic the schema without them, with
  `additionalProperties: false` on every object, and checks them on the parsed
  output for every provider. An object that allows other properties or
  declares none cannot be sent to Anthropic; the step fails before the call
  with a `Smith::WorkflowError`, and runtime readiness reports
  `:output_schema_unsupported` for an agent declared for Anthropic.
- An agent with no model and no fallback models fails its step with a
  `Smith::WorkflowError`; runtime readiness reports it (`:agent_without_model`).

Every response is billed and settles into budgets, whatever happens to its
output, and each rejected one leaves an `:output_rejected` trace naming its
attempt. The output errors share the failure family `output_failure`, persist
with a failed step, and are never retried by `Smith::Errors.retryable?`, a job
retry on `Smith::Errors.retryable_classes`, or a transition's
`retry_on Smith::AgentError`: Smith's own retry, fallback and repairs have run.

## Errors and retry

```ruby
Smith::Errors.retryable?(error)
# AgentError, DeadlineExceeded => true (always)
# OutputTruncated, OutputRefused, OutputInvalid (OutputFailure) => false
# DeterministicStepFailure, ToolGuardrailFailed => honors error.retryable
# everything else => false

Smith::Errors.retryable_classes
# => [Smith::AgentError, Smith::DeadlineExceeded]  (for ActiveJob retry_on)

Smith::Errors.retry_forbidden?(error)
# => true for terminal tool-evidence failures that must never be replayed
```

A nested workflow's step fails with the child's own error when the child
raises it, so these answers carry through nesting. When a tool ran inside the
child, the parent step's failure becomes `ToolOutcomeUncertain`, which is never
retried.

Workflow transitions can also declare a bounded local retry policy:

```ruby
transition :draft, from: :idle, to: :done do
  execute :writer
  retry_on Smith::AgentError, attempts: 3, backoff: 0.1, max_delay: 1.0
end
```

When no classes are passed, `retry_on` uses `Smith::Errors.retryable?`. No
attempt starts once the workflow's wall-clock deadline has passed.
This is a bounded local transition retry policy. What a receiver does with an
idempotency key remains host-owned.

For backoffs too long to sleep through in a worker, `durable: true` makes each
one a wait of the run instead:

```ruby
transition :charge, from: :approved, to: :charged do
  compute { |step| Payments.charge(order, idempotency_key: step.idempotency_key) }
  retry_on Payments::Timeout, attempts: 5, backoff: 60, max_delay: 3600, durable: true
  on_failure :charge_failed
end
```

A failed attempt the policy retries stores the run waiting (`awaiting.kind ==
:retry`, due when the backoff ends); the host schedules `expire_wait!` for that
time and then continues the run, which makes the next attempt under the step's
keys (new ones only after an attempt declared settled). See
`docs/PERSISTENCE.md`, Durable Retry.

Steps and tools get idempotency keys for the requests they send outside the
system, the same on every attempt and after a restore:

```ruby
transition :charge, from: :approved, to: :charged do
  compute { |step| Payments.charge(order, idempotency_key: step.idempotency_key) }
  retry_on Payments::Timeout, Payments::Declined, attempts: 3,
           new_idempotency_key_on: [Payments::Declined]
end
```

A retry keeps the keys, so a receiver that honours them drops a request that
took effect before a timeout. An error named in `new_idempotency_key_on:` (or
`step.fail!(..., new_idempotency_key: true)`) shows the attempt's own requests
took no effect, and the attempts after it use new keys. See
`docs/PERSISTENCE.md`, Replay Safety.

## Runtime Complexity

- Executable graph reachability is iterative `O(V + E)` time and `O(V)` space,
  using indexed outgoing transitions and runtime-equivalent successor rules.
- Smith-managed tool arguments are copied iteratively in `O(N + B)` time and
  `O(N + B)` bounded space for `N` expanded JSON value occurrences and `B`
  expanded encoded bytes. Reused subgraphs are charged for every serialized
  occurrence, native `Array` and `Hash` operations bypass hostile overrides, and
  every mutable container's native size is admitted before one shallow copy is
  made. Smith verifies the copy retained the admitted size before allocating or
  traversing children. One immutable dispatch collection remains authoritative
  from host admission through RubyLLM execution. The complete provider batch is
  bounded to 100 calls and 1 MiB of normalized UTF-8 call metadata. The capture
  boundary transfers temporary ownership of the provider collection and argument
  graph to Smith: callers must not mutate them concurrently. Smith detects changed
  cardinality and fails closed, but Ruby cannot prevent an unrelated writer from
  growing a caller-owned container between native size admission and the native
  copy without freezing that caller-owned object.
- Admitted tool-receipt settlement scans each batch once in `O(B)` time and
  `O(B)` state for `B` admitted Smith calls, including when an earlier terminal
  callback fails.
- Parallel execution is `O(B)` scheduling and result space for `B` branches,
  with at most `C = parallel_concurrency` active worker threads per top-level
  execution. Re-entrant fan-out inherits the same cancellation signal and uses
  only idle workers from the top-level execution context, falling back to the
  current worker when no capacity remains. Nested calls fail closed before the
  configurable nesting bound can exhaust Ruby's stack. Cancellation prevents
  queued branch bodies from starting;
  already-running branches are drained before control returns so work is never
  detached. Branch adapters must use bounded I/O and honor the cancellation
  signal. Hosts continue to own process-level concurrency and hard deadlines.
- Reservation and settlement across `L` declared budget dimensions and `D`
  operation dimensions is `O(L + D)` time and space. Receipt lookup is expected
  `O(1)`; no operation scans or copies the active receipt registry. Integer and
  Float amounts use exact decimal arithmetic internally.
- Retry delay calculation is `O(1)` time and space per attempt. A policy with
  `A` attempts performs at most `A` guarded operations and never materializes an
  exponential schedule.

## Development

Smith changes must not use brute-force graph search, validation, scheduling, or
class-generation algorithms. Document the relevant time and space complexity,
prefer indexed, linear, logarithmic, or otherwise bounded approaches, and treat
an avoidable asymptotic regression as a release blocker.

```bash
bundle install
bundle exec rspec
bundle exec rubocop
```

1,175 examples, MIT licensed. See [`CHANGELOG.md`](CHANGELOG.md) for the current
release surface.
