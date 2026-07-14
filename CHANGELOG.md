# Changelog

All notable changes to Smith are documented in this file.

Format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/). Versioning follows [Semantic Versioning](https://semver.org/spec/v2.0.0.html). Smith is pre-1.0 and under active development; expect occasional contract tightening between minor versions until 1.0.

## [Unreleased]

### Added

- Add opt-in restart-safe prepared-step recovery. Workflow classes bind a
  host-supplied executable `definition_digest`; hosts submit an immutable typed
  `PreparedStepRecovery.not_started` decision; Smith verifies the exact
  committed preparation before reconstructing a guarded boundary.
- Add exact-payload `replace_exact` and bounded `persistence_identity` adapter
  capabilities. Restart-safe execution atomically advances the durable payload
  from `prepared` to `dispatching` before transition work, preventing original
  and recovered processes from both dispatching the same operation.
- Separate restart-safe dispatch claim, commit confirmation, and transition
  execution so transactional hosts can atomically correlate their attempt
  ledger before any provider, tool, or deterministic step work begins.
- Add immutable, bounded `PreparedStepDispatch` receipts. An exclusive host that
  durably proves execution never started can reconstruct an exact committed
  `dispatching` boundary without replaying its claim.
- Add strict bounded `PreparedStep.deserialize` transport decoding and the
  typed `Sha256Hex` scalar.

- Expose `Workflow#pending_transition_name` so hosts can inspect the exact next
  transition without serializing workflow state or traversing the graph.
- Expose an immutable `Smith::Workflow::PreparedStep` descriptor for an active
  strict split-step boundary. Hosts can persist opaque token, transition,
  persistence-version, step-number, and preparation-digest identity without
  reaching into workflow internals or copying Smith state.
  `prepare_persisted_step!` retains its existing transition-name return value.
- Compute descriptor identity before persistence dispatch with bounded,
  canonical JSON hashing, preventing post-write validation failures and
  unbounded preparation work.
- Fence transactional split-step descriptors to an adapter-provided exact
  transaction identity. `ActiveRecordStore` uses Rails' public
  `current_transaction.uuid`; custom transactional adapters fail before writing
  unless they expose an equivalent identity.

### Changed

- Reject strict in-progress payloads before schema migration so a migration
  cannot clear the uncertainty marker and replay a transition.
- Keep an ambiguously acknowledged exact dispatch claim fail-closed in durable
  `dispatching` state. Smith does not infer or replay an uncertain external
  outcome.
- Run Redis versioned and exact-payload CAS inside redis-rb's native
  no-reconnect scope and do not replay either write after a transient
  connection failure; a lost acknowledgement is outcome-unknown and must be
  reconciled.
- Pin the executable definition digest for the complete split-step boundary and
  reject class digest drift before claim or execution.
- Make Active Record exact replacement one conditional SQL update over key and
  byte-exact payload while incrementing its optimistic-lock column. Validate
  the database primary key or an unconditional single-column unique key index
  through Active Record's table-keyed schema cache before each exact write.
- Resolve callable Redis command clients as clients rather than factories, and
  require a native reconnect-disabling scope before any Redis CAS begins.
- Treat a persistence identity as available in doctor diagnostics only when its
  value satisfies the same bounded non-empty contract used at runtime.

- Maintain a declaration-time outgoing-transition index. First-transition and
  terminal checks are constant-time; enumerating transitions from one state is
  proportional to that state's outdegree. Stable declaration precedence,
  subclass isolation, and transition redefinition semantics are preserved.
- Custom adapters that report an open transaction now require
  `transaction_identity` for strict split-step preparation. This intentionally
  tightens the 0.4.5 boolean transaction contract so later unrelated
  transactions cannot re-authorize a rolled-back descriptor.

### Verification

- Default suite: 1,116 examples, 0 failures.
- Focused prepared-recovery, persistence-adapter, and doctor suite: 104 examples,
  0 failures; new implementation files and focused changed files pass RuboCop and
  `git diff --check`.
- Practical gem execution: 30 restart-safe scenarios covering serialized
  preparation and dispatch recovery, exact-claim contention, corruption,
  definition drift, ambiguous acknowledgements, and Active Record
  commit/rollback coordination; a real redis-rb 5.4.1 run additionally proved
  direct-client and factory resolution plus bounded multi-client exact-claim
  contention.
- Smith Runtime host regression against the local Smith checkout: 712 tests,
  3,728 assertions, 0 failures.

## [0.4.5] - 2026-07-11

Patch release for generic host-coordinated workflow step boundaries and
fail-closed persistence correctness. Smith now exposes a bounded strict
split-step protocol while leaving transactions, scheduling, lifecycle records,
tools, and product policy under host ownership.

### Fixed

- Align `ActiveRecordStore#store_versioned` with Smith's persistence contract by
  comparing `expected_version` to the stored payload's `persistence_version`.
  Rails' optimistic-locking column remains an independent row-level CAS token,
  so consecutive workflow persists no longer report a false conflict after the
  initial insert.
- Fail closed when an Active Record host model does not have optimistic locking
  enabled on the adapter's configured `version_column`. Custom locking columns
  remain host-owned and must be configured on the model explicitly.
- Use Rails' native create-or-find savepoint for concurrent initial inserts,
  preserving callback rollbacks and distinguishing key collisions from other
  unique-constraint failures.
- Keep malformed payload-version handling consistent across versioned adapters,
  reject scalar state documents, fail closed when an explicit persisted version
  is invalid, and never replay an uncertain versioned write below a host-owned
  transaction boundary.
- Resolve string-backed Active Record models on each operation so host framework
  reloads cannot leave the adapter holding a stale class object.
- Add a generic strict split-step persistence contract for hosts that coordinate
  pre/post transition state without holding a transaction across provider or
  tool execution. Mutable execution state and non-expiring persistence policy
  are pinned for the boundary, subclass entry points remain guarded, and a
  proven transaction rollback can retry from the exact committed preparation.
  Same-transaction atomicity remains adapter- and host-owned.
- Prevent Memory, Redis, and Active Record versioned adapters from recreating a
  missing key when the caller expects a nonzero logical version. Missing state
  now reports `PersistenceVersionConflict` with `actual: :missing`.
- Bound split-step transition contract capture to cycle-aware `O(V + E)` traversal with explicit
  node, byte, and depth limits; reject opaque mutable values; freeze supported
  structured configuration; and preserve execution guards when workflow
  subclasses receive later prepends.
- Keep prepared transition execution on Smith's owned `advance!` path so host
  wrappers cannot run as transition authority inside an active boundary.
- Make the split-step aggregate own its internal require order so direct loading
  does not depend on `smith.rb` preloading implementation files.
- Require reconciliation before retrying an ambiguously acknowledged
  checkpoint and retain a single checkpoint witness, keeping retry state in
  constant space.
- Make Memory expiry atomic with version comparison, isolate mutable payload
  strings at its boundary, and pin Active Record column configuration.

### Verification

- Default suite: 1,045 examples, 0 failures.
- Focused split-step and versioned-adapter suite: 107 examples, 0 failures;
  changed files pass RuboCop and `git diff --check`.
- Practical gem execution: 30 distinct 20-step workflow classes, 600 Memory
  split steps, 1,000 Memory compare-and-swap writes, and 200 Active Record
  split steps with restore after every committed checkpoint.
- Smith Runtime host acceptance on Ruby 4.0.1 and Rails 8.1.3: 251 tests,
  816 assertions, 0 failures; 20 practical signed-package compiles produced
  valid Smith reports and cleaned every generated namespace.

## [0.4.4] - 2026-07-10

Patch release for provider-safe workflow handoffs. Smith keeps accepted agent
outputs in durable session history while adapting only the next provider call
when a completed workflow stage would otherwise look like an unsupported
assistant prefill.

### Fixed

- Adapt workflow-prepared provider input that ends with an accepted assistant
  result by adding a non-persisted user continuation for the next agent call.
  This preserves Smith session history while avoiding unsupported assistant
  prefilling on provider models that require a user turn before completion.
  Provider preparation now also reads string-keyed roles and content restored
  through JSON host persistence. Explicit assistant-prefill seed messages remain
  unchanged unless they match Smith's recorded accepted workflow output.

### Verification

- Default suite: 932 examples, 0 failures.
- Practical gem-level JSON persistence/restore probe with a 25-branch parallel
  handoff, provider-safe message ordering, non-persisted continuation, and
  explicit assistant-prefill preservation.
- Smith Runtime host verification on Ruby 4.0.1 and Rails 8.1.3: 139 tests,
  391 assertions, 0 failures, plus a process-level restored workflow run.

## [0.4.3] - 2026-07-05

### Documentation

- Clarify Smith's repair and wait-style loop boundaries: `retry_on` and
  `optimize` are executable today, deterministic repair and guarded re-entry
  are not native first-class contracts yet, and durable polling/wait semantics
  remain host-owned unless an explicit wait contract exists.

### Added

- Static graph-inspection contracts for `optimize` and `orchestrate`
  transitions, including bounded loop/delegation settings, schema labels, output
  contracts, exit policies, dispatch semantics, and transition-level resume
  guarantees.
- `Workflow.runtime_readiness`, a static diagnostic report that separates graph
  topology validity from runtime binding readiness without executing agents,
  tools, providers, jobs, or persistence.
- Runtime-readiness diagnostics for unresolved, invalid, lazy/uninspectable,
  model-less, and model-required agent bindings across execute, route,
  optimize, orchestrate, nested, and fan-out workflow shapes.
- Runtime-readiness metrics now expose direct counts and transitive counts folded
  in from nested workflows.
- `Smith::Agent::Registry.binding_for` and `.bindings` expose non-resolving
  registry inspection for diagnostics and host cleanup.
- Richer fan-out transition snapshot metadata: branch count, join state,
  ordered branch list, output contract, resume contract, and per-branch result
  contracts for named branch-result output.
- Direct doctor coverage for registered agent model-profile checks, including
  static primary and static fallback models, making safe-default model shaping
  explicit before hosts rely on runtime behavior.

### Changed

- `smith doctor --profile rails_persistence` now reports the full optional
  persistence capability surface (`store_versioned`, `record_heartbeat`, and
  `last_heartbeat`) instead of checking optimistic locking only.
- Workflow runtime value objects now live in dedicated files while preserving
  the existing public constants (`Smith::Workflow::RunResult`,
  `AgentResult`, `UsageEntry`, `BranchEnv`, and internal execution helpers).
- Release documentation now reflects the current heartbeat optional-capability
  contract and the RubyLLM integration boundary.

### Test coverage

- Default suite: 926 examples, 0 failures.
- Practical gem-level execution probe covering 30 varied workflows across
  strict/lax idempotency, same-agent parallel branches, heterogeneous fan-out,
  retry metadata, optimizer contracts, and orchestrator-worker flows.
- Smith Studio host verification against the local Smith checkout: 186 runtime
  tests and a 30-scenario generated-class lifecycle proof gate.
- Built `pkg/smith-agents-0.4.3.gem` and smoke-tested `require "smith"` from
  the unpacked package.

## [0.4.2] - 2026-07-02

Patch release for bounded fan-out and retry workflow primitives. This remains
workflow-first and host-owned: Smith executes declared transitions and exposes
inspection metadata, while durable scheduling, long waits, tool adapter
contracts, and deployment packaging stay with the host application.

### Added

- `fan_out branches: {...}` transition DSL for bounded heterogeneous
  multi-agent fan-out with stable branch keys and named aggregate results.
- `retry_on` transition DSL for bounded local retries using explicit error
  classes or Smith's built-in retryability classifier.
- Graph inspection metadata for `:fanout` transitions and retry policy details.

### Changed

- Fan-out branch execution preserves branch identity, branch-specific budgets,
  agent guardrails, tool guardrails, deadlines, and usage accounting.
- Parallel/fan-out failure handling now prefers the initiating branch error over
  cooperative cancellation errors.
- Failed-but-billable provider attempts are included in budget reconciliation
  for retry, fallback, and fan-out settlement paths.
- Retry `max_delay` remains a hard cap even when jitter is configured.

### Test coverage

- Default suite: 880 examples, 0 failures.
- Practical gem-level execution probe covering heterogeneous `fan_out`,
  same-agent parallel execution, `retry_on`, failed-but-billable budget
  settlement, cancellation cause preservation, branch input guardrail ordering
  before session preparation, graph metadata, and invalid declaration rejection.
- Added focused coverage for heterogeneous fan-out, retry policies,
  failed-but-billable retry budget accounting, cancellation cause preservation,
  and graph inspection metadata.

## [0.4.1] - 2026-06-28

Patch release for static workflow graph inspection. This is additive and diagnostic-only: Smith exposes declared workflow topology for hosts to render, lint, or cache without executing agents, advancing state, owning progress projection, or changing durability/recovery boundaries.

### Added

- `Smith::Workflow.graph` — returns a read-only inspection object for a workflow class.
- `Smith::Workflow.validate_graph` — returns a structured report with validity status, diagnostics, suggestions, transition snapshots, and graph metrics.
- Pre-runtime graph diagnostics for missing initial states, undefined transition states, unresolved `on_success` / `on_failure` targets, unresolved router route/fallback targets, target-state mismatch warnings, and unreachable-transition warnings.
- Transition snapshots that preserve declared names exactly and expose `name`, `from`, `to`, `kind`, success/failure targets, router routes, and router fallback.

### Test coverage

- Default suite: 862 examples, 0 failures.
- Touched Ruby files: 17 files inspected by RuboCop, 0 offenses.

## [0.4.0] - 2026-06-24

Two more host-ergonomic primitives that close the deferred-from-0.3.0 backlog: `Workflow.stuck_for?` for liveness probing and `Context.persist :auto` for write-tracked context persistence. Both are purely additive.

### Added

- `Smith::Workflow.stuck_for?(persistence_key:, threshold:, since: nil, adapter:)` — answers whether a workflow attempt is genuinely stuck. Path A (payload present): returns `true` when the workflow is NOT terminal and the heartbeat age (or fallback `payload['updated_at']` age) exceeds `threshold`. Path B (no payload + caller-supplied `since:`): returns `true` when `since` is older than `threshold`, handling the pre-persist gap window where consumers mark a status to `:processing` before Smith records any state. Terminal detection uses the real state-graph rule (`class.transitions_from(state).empty? && next_transition_name.nil?`).
- `Smith::Workflow.heartbeat_age(persistence_key:, adapter:)` — bare age accessor returning seconds since last heartbeat, or `nil` when no payload/heartbeat exists. Intended for dashboards.
- `Smith::PersistenceAdapter#record_heartbeat(key, ttl:)` and `#last_heartbeat(key)` — new optional adapter methods. Both join `OPTIONAL_METHODS`; `REQUIRED_METHODS` stays `%i[store fetch delete]`. v1 ships heartbeat write+read on `Memory` and `RedisStore`. `Workflow#persist!` calls `record_heartbeat` after a successful `store`/`store_versioned`; adapters that don't implement the methods fall through to `payload['updated_at']` parsing with a one-time warning per adapter class.
- `Smith::Context.persist :auto` — declarative mode where the workflow's persisted context is computed from the keys actually written via `DeterministicStep#write_context`. Backward-compat preserved: `persist :a, :b` continues to mean explicit allow-list. `persist :auto, also: [:user_message]` declares the input seed list (initial-context keys must be enumerated here to round-trip). The workflow records each `write_context` key into `@persisted_keys` (a `Set`, protected by a Mutex for parallel safety) and slices through it on `:auto`-mode `persisted_context`.
- `Smith::Workflow#persisted_keys` — frozen read-only accessor for the recorded auto-tracked keys.
- New top-level `to_state` field `:persisted_keys` (sorted Array of Symbols). Round-trips through restore. Pre-`:auto` payloads with no key list seed `@persisted_keys` from the keys present in the stored context Hash, treating that as lossless migration.

### Changed

- `Smith::Context.persist` signature gains an `also:` keyword. Passing `also:` without `:auto` raises `Smith::WorkflowError`. Passing `:auto` with additional positional args also raises.
- `Smith::Workflow#persist!` now calls `record_heartbeat` on adapters that support it. Failed `store_versioned` (PersistenceVersionConflict) does NOT bump the heartbeat.
- `Smith::PersistenceAdapters::RedisStore#delete` now deletes both the payload key and the heartbeat sidecar key in a single `DEL` call.
- `Smith::Workflow.to_state` includes the new `:persisted_keys` field unconditionally (forward-compatible payload shape for explicit-mode workflows too).

### Test coverage

- Default suite: 857 examples, 0 failures (+22 stuck_for/heartbeat, +19 persist :auto).
- `SMITH_AR_SPECS=1` suite: 872 examples, 0 failures.

## [0.3.0] - 2026-06-24

Two host-ergonomic primitives that absorb boilerplate consumer Execution wrappers were reinventing. Both are purely additive — existing workflows continue to work without changes.

### Added

- `Smith::Workflow::ExecutionFrame` — absorbs the five-flag bookkeeping pattern (`claimed`, `result_obtained`, `recorded`, `intentional_retry`, `finalize_succeeded`) duplicated across host Execution wrappers. The host yields its per-attempt work into `ExecutionFrame.run`, records lifecycle milestones via `mark_*!` setters, and the frame's ensure invokes `on_clear` (when the canonical clear decision says so) and `always_ensure` (whenever claimed, independent of the clear decision; covers the advisory-lock-release case). `workflow:` accepts a Smith::Workflow instance OR a callable that resolves lazily at ensure-time. `OrderingError` and `AlreadyRun` inherit from `Smith::Error`, not `Smith::WorkflowError`, so host `rescue Smith::WorkflowError` blocks cannot silently downgrade ordering bugs. Logger fallback chain: explicit `logger:` kwarg, then `Smith.config.logger`, then a last-resort `Logger.new($stderr)`.
- `Smith::Workflow::Claim.atomic` — AASM-aware claim helper. Wraps `record.public_send(transition_via)` inside `transaction_owner.transaction` (default: `model_class`). Inside the transaction: `lock.find(id)`, case-on-status, invoke the AASM event when status is in `from_statuses`. Returns the reloaded record on success, `nil` when status is in `terminal_statuses`, raises `Smith::Workflow::Claim::UnexpectedStatus` when status is outside `from_statuses ∪ terminal_statuses` (default `:raise`; opt into `:ignore` or `:log` via `on_unexpected_status:`). Raises `ArgumentError` when `transition_via:` is nil AND the model responds to `.aasm`, preventing silent AASM-callback drops.
- `Smith::Workflow::Claim.cas` — single-statement CAS via `update_all` with `where(status: from_statuses)`. Returns the reloaded record or `nil` if rowcount is zero. Stamps `updated_at` via the injected `now:` lambda. Does NOT invoke AASM events; intended for non-AASM CAS sites.
- Both `Claim` strategies load lazily — `lib/smith/workflow/claim.rb` does NOT const-reference `::ActiveRecord` at module load. Both raise `Smith::Workflow::Claim::AdapterUnavailable` when invoked without AR present, so Smith stays gem-load-time decoupled from AR.

### Changed

- `activerecord ~> 8.0` and `sqlite3 ~> 2.0` added as development/test dependencies (NOT runtime). The Claim spec harness in `spec/support/active_record_harness.rb` is ENV-gated behind `SMITH_AR_SPECS=1`; when unset, `:ar`-tagged examples are excluded so the default suite never loads AR.

### Test coverage

- Default suite: 816 examples, 0 failures (existing + ExecutionFrame + Claim load-hygiene).
- `SMITH_AR_SPECS=1` suite: 831 examples, 0 failures (adds 15 `:ar`-tagged Claim specs).

## [0.2.0] - 2026-06-24

This release tracks two thematic refactors that together harden the agent-invocation and persistence layers, plus a third slice that closes EvaluatorOptimizer ergonomics gaps surfaced by host adoption:

- **Phase A**: replaces the Opus 4.7 monkey-patch with a generic, library-shipped capability-aware normalizer; fixes the previously-broken cross-provider fallback path (Claude → gpt-5.5 + tools + thinking) by routing through `/v1/responses` when supported or gracefully dropping incompatible tools otherwise.
- **Phase B**: hardens the persistence layer with TTL, retry, optimistic locking, schema versioning, seed-drift validation, step-in-progress idempotency, and an in-process Memory adapter for test isolation.
- **Phase C**: extends EvaluatorOptimizer with `evaluator_context: :inject_state`, a `before_eval:` deterministic hook, and `on_exhaustion:` / `on_converged:` / `on_threshold:` graceful-exit modes; adds `Smith::Errors.retryable?` to own the retryable-error classification host-side.

### Added

#### Phase C: EvaluatorOptimizer ergonomics + retry classification

- `Smith::Errors.retryable?(error)` classifier owned at the library level. `AgentError` and `DeadlineExceeded` are always-retryable; `DeterministicStepFailure` and `ToolGuardrailFailed` honor their `retryable` attribute (opt-in at the raise site); all other Smith errors and non-Smith errors return false. Replaces ad-hoc case statements in host Execution / Job wrappers.
- `Smith::Errors.retryable_classes` returns the frozen always-retryable class list for ActiveJob `retry_on` allow-lists.
- `optimize evaluator_context: :inject_state` opts the evaluator into the same `prepared_input` the generator was built with. The evaluator now sees the workflow's `seed_messages` plus `Context.inject_state` observations (voice profiles, research artifacts, source URLs) plus the candidate as a turn-local user message. Default `nil` preserves the legacy candidate-only payload.
- `optimize before_eval: proc { |state, context| ... }` runs after the generator produces a candidate and before the evaluator is invoked. The hook receives the `OptimizationState` and the live workflow `@context` (mutable). Typical use: a deterministic validator (regex kill-list, structural check) writes findings into context so the evaluator surfaces them deterministically instead of rediscovering by feel each round.
- `optimize on_exhaustion:`, `on_converged:`, `on_threshold:` graceful-exit modes. Each accepts `:raise` (default, legacy behavior), `:return_last` (return the most recent candidate as the step output), or a callable receiving the `OptimizationState`. Lets refinement workflows opt into "best of N rounds" semantics instead of terminal `WorkflowError`.

#### Phase A: capability-aware request shaping

- `Smith::Models` registry (Dry::Container-backed) for application-side `Smith::Models::Profile` overrides; mirrors the `Smith::Agent::Registry` stale-reload-binding pattern for Rails autoreload safety.
- `Smith::Models::Profile` immutable capability record (`Data.define`) covering thinking_shape, accepts_temperature, tools_with_thinking_native, tools_with_thinking_route, and a derived `endpoint_mode`.
- `Smith::Models::Inference` library-shipped pattern rules describing each provider family's payload shape (Anthropic Opus 4.7+ adaptive, Anthropic 4.0-4.6 budget_tokens, OpenAI gpt-5 family reasoning_effort + responses route, OpenAI gpt-4.x, Gemini 2.5+ budget_tokens, etc.). Smith ships zero hardcoded model_ids; new model releases that match an existing pattern work without library changes.
- `Smith::Models::Normalizer.apply!(chat, profile:)` per-attempt request shaper. Translates Anthropic Opus 4.7+ thinking to the adaptive payload shape (`@params[:thinking] = { type: "adaptive" }` + `output_config[:effort]`), nulls temperature where the resolved profile forbids it, routes `(gpt-5 + tools + thinking)` via `openai_api_mode: :responses` when supported, drops incompatible tools otherwise. Hooks at `Smith::Agent.chat()` so direct callers outside the workflow lifecycle are normalized too.
- `Smith::Agent::RESERVED_INPUT_NAMES = %i[model_id provider endpoint_mode]` auto-injected into `runtime_context` per attempt from the resolved profile. The `Smith::Agent.inputs` getter returns reserved ∪ user (frozen, deduplicated); the setter raises `Smith::AgentError` if a user-declared name collides with a reserved name.
- `Smith::Tool.compatible_with(...)` DSL for declaring per-(provider, endpoint) tool compatibility. `Smith::Tool.inherited` dups the spec so subclasses inherit the parent's compatibility metadata.
- `Smith::Tools::Think` declares `compatible_with :anthropic, :gemini, openai: :responses`. Drops gracefully on OpenAI chat-completions when `openai_api_mode = :off`, runs via `/v1/responses` when `:auto`.
- `Smith::Providers::OpenAI::Routing` prepend installed onto `RubyLLM::Providers::OpenAI`; routes to `Smith::Providers::OpenAI::Responses` when `@params[:openai_api_mode] == :responses`.
- `Smith::Providers::OpenAI::Responses` adapter for `/v1/responses` payload assembly + HTTP dispatch + response parsing. Vendored from [crmne/ruby_llm PR #770](https://github.com/crmne/ruby_llm/pull/770) at pinned SHA `a84517db65d3774c6b129dc88032fe32c8dbc722` (render/parse helpers verbatim with namespace requalification; `complete`, `format_role`, and `resolve_effort` are Smith-authored glue). Retirement path documented in `UPSTREAM_PROPOSAL.md`. Streaming is intentionally not yet supported; block-given calls raise `NotImplementedError` with a clear workaround.
- `Smith::Providers::OpenAI::ToolsExtensions` adapter for OpenAI tool format helpers consumed by Responses (response_tool_for, parse_response_tool_calls, build_response_tool_choice). Vendored from the same PR + SHA.
- `Smith.config.openai_api_mode` setting (`:auto` | `:off`, default `:auto`) with constructor validation.
- `Smith.config.trace_normalizer` setting (default true) gating `:normalizer_decision` trace events.
- Doctor checks: `models.coverage` (warns when registered agents reference models without an explicit profile or matching Inference rule) and `config.openai_api_mode` (warns when `:auto` is configured but the Responses adapter is absent).
- `UPSTREAM_PROPOSAL.md` documenting the proposed RubyLLM extensions (`Capabilities::Profile`, `Provider.before_complete` hook, public `without_thinking` / `without_temperature` chat builders) and the retirement checklist for Smith files that go away when the upstream API ships.

#### Phase B: persistence hardening

- `Smith::PersistenceAdapters::Memory` in-process Hash adapter (Monitor-synchronized), supports TTL via stamped expiry and optimistic locking via `store_versioned`. Auto-selected by `Smith.persistence_adapter` when `persistence_adapter` is nil and `Smith.config.test_mode = true`, so test suites can skip wiring Redis/Rails.cache in `spec_helper.rb`.
- `Smith::PersistenceAdapters::Retry.with_retries(operation:, transient:)` exponential-backoff wrapper used by all I/O-bound adapters. Each adapter declares its own `TRANSIENT_ERRORS` constant matching its backend (Redis transient errors via class-name lookup, CacheStore Errno errors, ActiveRecord connection errors); Memory adapter passes an empty list (in-process, no transient errors).
- `Smith::PersistenceIOError` raised after retry exhaustion, wrapping the underlying cause with `#operation` and `#cause` fields.
- `Smith.config.persistence_ttl` global TTL setting (Integer/Float seconds; nil = no expiry).
- `Smith.config.persistence_retry_policy` setting (defaults: `{ attempts: 3, base_delay: 0.1, max_delay: 1.0 }`).
- `Smith.config.test_mode` setting (default false).
- `Smith::PersistenceAdapters::OPTIONAL_METHODS = %i[store_versioned]` and `Smith::PersistenceAdapters.supports?(adapter, capability)` for capability introspection. `warn_missing_versioning(adapter)` issues a one-time per-adapter-class warning when an adapter doesn't implement `store_versioned`.
- `store_versioned(key, payload, expected_version:, ttl:)` on RedisStore (WATCH/MULTI/EXEC), Memory (Monitor-synchronized version compare), and ActiveRecordStore (Rails optimistic locking on a configurable `lock_version` column). CacheStore deliberately does not implement it (cache backends lack uniform CAS semantics).
- `Smith::PersistenceVersionConflict` raised on stale `expected_version` or detected concurrent writes; carries `#key #expected #actual` fields. Workflow's `@persistence_version` stays at the pre-failure value so callers can rescue → restore → retry.
- `@persistence_version` ivar in `Smith::Workflow` (default 0); incremented after each successful persist; restored from the persisted payload. Pre-versioning payloads (missing key) are treated as version 0 for backward compatibility.
- `Workflow#persist!` consults `Smith::PersistenceAdapters.supports?(adapter, :store_versioned)` and falls back to plain `store` with the one-time warning when absent.
- `Workflow.persistence_schema_version(N)` DSL (default 1) + `Workflow.migrate_from(N) { |payload| ... }` blocks. `to_state` carries `:schema_version`; restore walks `migrate_if_needed` one step at a time. Defensive cursor advancement (Smith advances `:schema_version` if a migration block forgets to). Downgrades and unbridged gaps raise `Smith::PersistenceSchemaMismatch` with `#workflow #stored #current` fields.
- `Workflow.seed_validation(:strict | :warn | :off)` DSL (default `:off`) gating SHA256 digest comparison of `seed_messages` at restore time. `@seed_digest` is computed at construction and persisted in `to_state`; restore re-evaluates the seed builder against the restored `@context` and compares. `:strict` raises `Smith::SeedMismatch`; `:warn` logs via `Smith.config.logger&.warn`. Default `:off` reflects that many seed builders are non-deterministic (timestamps, UUIDs, request-scoped data) and would surface false drift on every restore.
- `Workflow.idempotency_mode(:strict | :lax)` DSL (default `:lax`). Strict mode stamps a `@step_in_progress` marker before each pre-advance persist and clears it after the post-advance persist. Restore raises `Smith::StepInProgressOnRestore` (with `#persistence_key`) when the marker is set under `:strict`, signalling that a prior worker crashed mid-step and re-running could double-execute non-idempotent agent calls or tools.
- `Workflow.persistence_ttl(seconds)` DSL (positive Numeric) for per-workflow TTL override. Resolution precedence: class DSL > `Smith.config.persistence_ttl` > nil. `Workflow#persist!` forwards `ttl:` to the adapter only when non-nil, so external duck-typed adapters with bare `store(key, payload)` keep working as long as the host doesn't opt into TTL.
- TTL pass-through in all native-supporting adapters: RedisStore (`ex:`), CacheStore (`expires_in:`, RailsCache inherits), Memory (stamped expiry). ActiveRecordStore TTL is deferred (would need an `expires_at` column + sweeper job; documented inline).
- Doctor check: `persistence.capabilities` warns when the configured adapter is missing optional capabilities (currently `store_versioned`), surfacing the silent fallback eagerly under the `:rails_persistence` profile.

### Changed

- RubyLLM dependency bumped from `~> 1.14` to `~> 1.15`. RubyLLM 1.15 ships `claude-opus-4-7` and `gpt-5.5` aliases natively, so Smith no longer needs to runtime-register them.
- `Smith::Workflow::UsageEntry`, `AgentResult`, and `BranchEnv` Structs converted to `keyword_init: true` for forward/backward compatibility on persisted state. `UsageEntry.from_h` slices the input hash to known members (unknown keys silently dropped, missing keys default to nil) and symbolizes `:agent_name` + `:attempt_kind` for backward compatibility with callers that consume them as Symbols.
- `Smith::Agent.chat()` is now a Smith-owned override that resolves the model's `Smith::Models::Profile`, injects reserved input values into `runtime_context`, nil-fills declared user inputs, calls `super`, then runs `Smith::Models::Normalizer.apply!`. Direct callers no longer require special handling.
- `Smith::Agent.inputs` getter returns the union of user-declared and reserved input names (frozen); setter merges (RubyLLM's bare `@input_names = names` would replace and lose reserved names).
- Persistence adapters now wrap `store/fetch/delete/store_versioned` in `Smith::PersistenceAdapters::Retry.with_retries`. The Memory adapter is intentionally skipped (in-process, no transient errors).
- `Smith.persistence_adapter` caching now keys on a signature that includes `test_mode` so toggling it invalidates the cached adapter.

### Removed

- `Smith::RubyLLMModels` module (`lib/smith/ruby_llm_models.rb`) and its spec. Replaced by `Smith::Models` + `Smith::Models::Inference`.
- `Smith::RubyLLMAnthropicOpus47Compat` monkey-patch on `RubyLLM::Providers::Anthropic`. Replaced by `Smith::Models::Normalizer.apply!` at chat construction.

### Migration notes

- Hosts that constructed `Smith::Workflow::UsageEntry.new(usage_id, agent_name, …)` with positional arguments must switch to keyword form (`UsageEntry.new(usage_id:, agent_name:, …)`). Same for `AgentResult` and `BranchEnv`. The `from_h` constructor is unchanged and continues to accept legacy persisted hashes.
- Hosts that opt into `Smith.config.openai_api_mode = :auto` (now the default) and hit `(gpt-5 family + tools + thinking)` will route via `/v1/responses` using the vendored adapter. Streaming over the Responses endpoint is not yet supported; block-given completions raise `NotImplementedError` with a clear workaround (either drop the block for sync mode, or set `openai_api_mode = :off` for graceful tool-dropping via chat-completions). Sync (non-streaming) completions work end-to-end against OpenAI's `/v1/responses`.
- Hosts running ActiveRecordStore with optimistic locking enabled must add a `lock_version` integer column (default 0) to their AR-backed persistence model:
  ```ruby
  add_column :workflow_states, :lock_version, :integer, default: 0
  ```
  Smith raises `ArgumentError` with the exact migration command if the column is absent and `store_versioned` is invoked.
- Hosts using cache-backed persistence adapters (`CacheStore`, `RailsCache`, `SolidCache`) get a one-time per-adapter-class warning at first persist that optimistic locking is unavailable; the workflow falls back to plain `store` without raising. Switch to `RedisStore`, `ActiveRecordStore` (with `lock_version`), or `Memory` (tests) for full optimistic-locking coverage.
- Hosts subclassing `Smith::Tool` and declaring tools that are designed for specific provider families should add `compatible_with` declarations so the normalizer can route or drop appropriately. Tools without a declaration are treated as universally compatible (preserves pre-refactor behavior for hosts that haven't opted in).

## [0.1.0] - Initial public-track release

Initial pre-release. No formal changelog prior to the Phase A/B refactor.
