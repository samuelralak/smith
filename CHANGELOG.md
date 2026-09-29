# Changelog

All notable changes to Smith are documented in this file.

Format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/). Versioning follows [Semantic Versioning](https://semver.org/spec/v2.0.0.html). Smith is pre-1.0 and under active development; expect occasional contract tightening between minor versions until 1.0.

## Unreleased

### Added

- `fallback_models` accepts a context block, matching the dynamic
  `model { |context| ... }`. `fallback_models { |context| [...] }` is evaluated
  once per agent invocation with the workflow context, and its entries pass
  exactly the static form's validation: every entry needs an explicit
  provider. An unqualified or invalid entry fails the step with
  `Smith::WorkflowError` before any provider attempt, and that error is not
  retried: `Smith::Errors.retryable?` is false for it, so a `retry_on` without
  error classes, `retry_on Smith::AgentError`, and host retries built on
  `Smith::Errors.retryable_classes` all leave it failed, unlike an invalid
  `model` block result, which raises the retryable `Smith::AgentError`. The
  chain keeps its de-duplication. Declaring entries and a block together raises
  `ArgumentError`; a later static declaration clears the block and a later
  block clears the static list; subclasses inherit the block. Graph
  inspection, runtime readiness, and the doctor model check never call the
  block: `fallback_models` returns `nil` for the block form and
  `fallback_models_block` exposes the block. `resolve_fallback_models(context)`
  evaluates the block, or returns the static qualified list (empty when none
  is declared) when no block is configured. Resolution is `O(F)` time and
  space for `F` returned entries. The static form is unchanged.
- Every `:provider_call` trace carries `agent_name`, the registered name of
  the agent that made the attempt (the value its usage entries carry), so a
  generator and an evaluator sharing one `optimize` round, and so one
  transition and round, stay apart; it is omitted for an unregistered agent.
  When the provider reported usage, the trace also carries `input_tokens` and
  `output_tokens`: the totals of the attempt's usage entries, covering a
  successful completion, a failed attempt's completed tool-loop prefix, and
  the usage a failed attempt's error reported. Both are omitted when the
  provider reported none. A trace adapter can therefore record a complete
  attempt when it ends instead of waiting for a step checkpoint. Token counts
  are metadata, never content: `trace_content false` does not hide them.
  Hosts with a `trace_fields` allowlist for `:provider_call` must add these
  keys to receive them. The fields are documented in `docs/CONFIGURATION.md`.
- `optimize`'s `before_eval` may reject a candidate. A returned Hash whose
  `accept` (Symbol or String key) is `false` is that round's evaluation: it is
  normalized and validated exactly as evaluator output (`feedback` required,
  a numeric `score` when `improvement_threshold` is set), the evaluator is not
  called for the round, and the loop continues as a rejection, so the
  feedback reaches the generator's refinement turn and `on_exhaustion` applies
  when rounds run out. Any other return value, including `nil` and a Hash
  with `accept: true`, is ignored exactly as before and the evaluator judges.
  A rejected round records only the generator's usage and `:provider_call`.
  Documented in the Evaluator-Optimizer section of `docs/PATTERNS.md`.
- `optimize`'s verdicts are an output. Each valid round's evaluation is
  recorded as `{ round:, source:, verdict: }`: the optimizer round (the one
  usage entries and traces carry), `:evaluator` or `:before_eval` for the one
  that gave it, and the evaluation as normalized, every field the evaluator's
  schema declares included, as a frozen copy. Once its loop has run, the
  step's record carries its verdicts under `:evaluations` whether the step
  completed or failed (a completion that fails after the loop, such as a split
  step's snapshot, included), the verdict that ends the loop included, each
  also naming its `attempt`, the retry policy's attempt that ran the loop: a
  step `retry_on` runs again starts its loop afresh with rounds from 0, and the
  earlier attempt's verdicts stay before the new ones. `RunResult#evaluations`
  lists every optimize step's verdicts in step, attempt and round order as
  frozen records with the step's `transition`, and
  `OptimizationState#evaluations` gives a callable a frozen copy of its own
  loop's verdicts so far. A step that failed before its loop, and every other
  step, gains no key; a nested workflow's verdicts stay on its own run.
  Verdicts are content, so no trace carries them, and like `steps` they
  belong to the run that executed the step: nothing is persisted and a
  terminal restore has none. Before this, a rejection's feedback lived only in
  the loop and an accepted verdict was discarded, so a host could not see why
  a candidate was sent back. Documented in the Evaluator-Optimizer section of
  `docs/PATTERNS.md`.
- `Smith::StepInProgressOnRestore` gains `state`, the persisted state the
  interrupted step started from (a Symbol), and `transition`, the next
  transition the payload records (such as a routed one), else `nil`, so a
  host can tell which step died without reading Smith's payload. Both are set
  wherever restore raises it and default to `nil` for any other construction;
  the constructor stays backward compatible and the message gains only
  ` state=...` when the state is known.

### Changed

- Contract tightening: an `optimize` round's verdict, now recorded as an
  output, must hold JSON values only (Hashes with String or Symbol keys,
  Arrays, Strings, Symbols, Integers, finite Floats, true, false, nil), and a
  step's verdicts together must fit the limits a split step's record is held
  to (`ExecutionResultSnapshot`'s depth, node and byte caps). A round whose
  verdict breaks either, most likely a rejection `before_eval` returned
  holding an object or a very large feedback, now fails the step with
  `Smith::WorkflowError` at that round, in every run mode, keeping the
  verdicts recorded before it. Before, such a verdict was never recorded and
  the loop went on.
- **Breaking:** a deterministic step's `write_outcome` is deep-symbolized
  when written, matching restore. A live `RunResult#outcome_payload` (and
  `RunResult#outcome`) now has Symbol keys at every depth, so a host reading
  String keys from a live payload must switch to Symbol keys. Restored
  payloads were already symbolized, so an outcome now reads identically live
  and after a JSON restore. Persisted JSON is unchanged.
- Contract tightening: `ActiveRecordStore` refuses to write with a non-nil
  TTL instead of silently ignoring it, since it has no expiry column.
  `store`, `store_versioned`, and `replace_exact` raise `ArgumentError`
  before touching the database. Reads and deletes take no TTL, and resolving
  the adapter never refuses, so `restore`, `persisted_state_exists?`,
  `clear_persisted!`, `stuck_for?`, and `heartbeat_age` keep working while a
  TTL is configured. A global or per-workflow `persistence_ttl` with this
  adapter is refused by the initial checkpoint that `run_persisted!` and
  `advance_persisted!` write before their first step, so no step runs before
  the refusal. A nil TTL (the default) is unaffected. `smith doctor
  --durability` fails a new `durability.ttl` check when the configured
  adapter is an `ActiveRecordStore` and `Smith.config.persistence_ttl` is
  set. The README, `docs/CONFIGURATION.md`, and the `persistence_ttl` DSL
  comment no longer claim this adapter honours TTL.
- Contract tightening: workflow and agent `budget` declarations raise
  `ArgumentError`, naming the accepted keys, when given a key Smith does not
  read; previously such a key was accepted and ignored. Workflow budgets
  accept `total_tokens`, `token_limit`, `total_cost`, `tool_calls`, and
  `wall_clock`; agent budgets accept `token_limit`, `cost`, `wall_clock`,
  `tool_calls`, `total_tokens`, and `total_cost`. `wall_clock` is in seconds:
  the README budget example used the ignored `wall_clock_ms: 30_000` and now
  uses `wall_clock: 30`. The check is `O(K)` time and space for `K` declared
  keys. State written by 0.10.0 keeps restoring after the host removes such a
  key: 0.10.0 reserved every declared key at each agent call, so it could
  persist a consumed entry like `"wall_clock_ms" => 0`, and restore now drops
  consumed entries (String or Symbol keys) for dimensions the workflow no
  longer declares. An undeclared dimension has no limit, so dropping it is
  safe. The filter is `O(D + C)` for `D` declared and `C` consumed keys.

### Fixed

- `DeterministicStep#last_output` returned `nil` after a JSON restore,
  because a restored session message carries a Symbol key with a String role
  value. `last_output` now accepts a Symbol or String role under either key
  form. Restored messages keep the shape 0.10.0 gives them (Symbol keys, JSON
  values such as `role: "assistant"`).
- Restored failures keep their type. `ProviderPermanentFailure`,
  `BudgetExceeded`, and `GuardrailFailed` get their own failure families
  (`provider_permanent_failure`, `budget_exceeded`, `guardrail_failed`) where
  they were `other`, and restore as their own classes where they restored as
  `RuntimeError`. `BlankAgentOutputError` keeps the `agent_error` family and
  restores as itself where it restored as a plain `AgentError`.
  `ProviderPermanentFailure` and `BlankAgentOutputError` gain `details` (each
  value bounded to 512 bytes) and `from_details`, so `provider`, `model_id`,
  `source_error_class`, `agent_name`, and `model_used` survive a restore.
  Details stay JSON-normalized, and `FailureRecordValidator` rejects malformed
  details, or one of these classes claiming another family, with
  `Smith::PersistedFailureInvalid`. Records written by earlier versions (these
  classes under `other`, or `BlankAgentOutputError` without details) keep
  restoring exactly as before. The new families also appear as `error_family`
  on failed `:transition` traces and `StepFailed` events. Composite branch
  failure evidence (`Workflow::Composite::ErrorEvidence`) still classifies
  these three errors as `other`. Rollback: 0.10.0 checks `error_family` and
  `error_cause_family` against its own family list, so any persisted payload
  whose `last_failed_step`, or its cause, carries one of the new families
  fails to restore under 0.10.0, whether the run is terminal or not; clear or
  settle such runs before rolling back.
- A failed or aborted attempt's `:provider_call` trace now carries
  `error_class`: the exception's class name, bounded to 512 bytes by the
  diagnostic text helper (`anonymous_error` for an anonymous class). It also
  carries `error_cause_class`, the class name of the error's direct cause
  (`Exception#cause`, else the error's `wrapped_exception`), captured the same
  way and omitted when there is no cause: a `Faraday::ConnectionFailed`
  wraps both never-connected causes (`Errno::ECONNREFUSED`, `SocketError`,
  `Net::OpenTimeout`) and lost-after-sending ones (`EOFError`,
  `Errno::ECONNRESET`), and a host deciding whether an attempt may have been
  billed needs to tell them apart. Messages never ride the trace. Hosts with a
  `trace_fields` allowlist for `:provider_call` must add `:error_class` and
  `:error_cause_class` to receive them.
- `inject_state` injects only non-blank text. A formatter returning `nil` or
  whitespace-only text no longer adds a bare `[smith:injected-state]` system
  message, and when a formatter that returned text now returns blank, the
  stale injected-state message is removed from session history. Injection
  remains one linear scan over the session.
- Restore and timestamp asymmetries. The `provider` in
  `last_agent_execution`, read by `DeterministicStep#last_agent_provider`,
  restores as the Symbol a live run holds where it restored as a String.
  `created_at` is now written with microsecond precision (`iso8601(6)`), so a
  `wall_clock` deadline no longer fires up to a second early; the early firing
  affected live runs too, since the deadline is always computed from the
  stored string. `updated_at` is written with the same precision at every
  step, so it never reads earlier than `created_at`. Payloads with
  whole-second timestamps still restore.
- `optimize` sends a structured candidate (a Hash or Array from an
  `output_schema` generator) to the evaluator, and replays it as the
  refinement round's assistant turn, as JSON, using the serialization Smith
  applies at the provider boundary, where it sent Ruby `inspect` notation.
  String candidates are unchanged.
- A budget reservation of the reported remaining amount no longer raises
  `BudgetExceeded` far below the limit. `Budget::Ledger#remaining` returned
  the Float nearest the exact remaining amount, and reserving it re-reads its
  shortest decimal form, which after Float-priced costs sits above the exact
  amount about half the time: a serial step on a $0.50 `total_cost` budget
  failed its third call at $0.0707. `remaining` now returns a value that
  never reads back above the exact amount, so it may read one ulp lower than
  before. `Budget::Ledger#remaining_share(key, parts)` is a new public method
  that returns one of `parts` equal shares that all fit, which fan-out branch
  estimates now use (a `total_cost: 0.2` budget split across three branches
  failed with nothing spent). Integers keep floor division; a Float steps
  down in `O(1)` ulp steps. Amounts stay Integer or Float in and JSON-safe
  numerics out.
- `smith doctor`'s `persistence.capabilities` check reports an adapter that
  fails to resolve as a failed "Persistence adapter configuration is invalid"
  check carrying the resolution error, where it reported "No persistence
  adapter configured".
- A swallowed `on_step:` callback error is logged with its class after the
  message (`Smith::Workflow on_step callback error: <message> (<class>)`),
  where only the message was logged. It is still swallowed.

## [0.10.0] - 2026-08-24

### Added

- Last-serial-agent-execution attribution. A deterministic (`compute`) step can
  now read the model and provider that actually served the most recent serial
  `execute :agent` step via `DeterministicStep#last_agent_model` /
  `#last_agent_provider` (symmetric with `#last_output`, which returns that
  step's content). The value is the resolved model/provider after fallback
  resolution, so a step that failed its primary and completed on a
  `fallback_models` entry reports the model that actually ran, never the
  configured primary. It is durable lifecycle state (persisted in `to_state` as
  `last_agent_execution`, restored across crash/resume), not a trace scrape, and
  is `nil` until a serial agent step runs. Backward compatible: pre-upgrade
  states have no `last_agent_execution` key and restore to `nil`; old readers
  slice off the unknown key.

### Fixed

- Structured agent outputs recorded as session messages (Hash or Array
  content) are now serialized to JSON at the RubyLLM provider boundary when
  replayed to a later agent step. RubyLLM treats a Hash message content as
  attachments and opens each value as a file, so replaying a prior structured
  output to the next agent in a workflow session raised `Errno::ENOENT`. The
  session store is unaffected: `last_output` and persisted `session_messages`
  keep the raw structured value; only the provider-facing copy is serialized.

## [0.9.0] - 2026-08-03

### Upgrade notes

- Rollback after running fan-out branches under this version is a one-way
  door for those runs: composite branch effects written with attribution
  values (usage entries) or batch-correlated `tool_call_id` capture entries
  fail an older gem's exact-key validation at reduction or recovery.
  Drain in-flight composite runs before rolling the gem back; plain
  checkpoint payloads are unaffected (restored pre-attribution documents
  re-serialize byte-identically, and old readers slice off unknown keys).
- Hosts with a configured trace adapter see new output on upgrade without
  any host change: one `:provider_call` line per provider attempt, one
  `:cost` line per priced completed invocation, failed `:transition` lines
  marked `outcome: :failed`, and ambient attribution keys (including
  `execution_key`, the Smith persistence key) merged into every payload.
  Identifier-only, but plan for the volume and shape change, especially
  with `Smith::Trace::Logger` in production.
- Hosts with a `trace_fields` allowlist for `:transition` must add
  `:outcome` (and the error keys they want) or failed transitions render
  indistinguishable from successes under the allowlist.
- `Smith::Trace::Memory` is now bounded (default 10,000 entries, silent
  drop with `dropped_count`); previously it accumulated without limit.

### Added

- Add `Smith::Attribution`, an immutable thread-local execution attribution
  context (`execution_key`, `transition`, `from`, `to`, `branch_key`,
  `round`). Workflow execution installs it per step (the `execution_key`
  defaults to the persistence key of a persisted run), fan-out carries it
  into branch threads and overlays the branch key, and evaluator-optimizer
  rounds overlay the round index. Hosts can seed an outer scope with
  `Smith::Attribution.with(execution_key: ...)` around non-persisted runs.
  Restoration inside workflow execution rides `ThreadContextSnapshot`, which
  now tracks the attribution thread key. Scope overlays are nil-ignoring
  (`Context#merge`), but the per-step facts (`transition`, `from`, `to`)
  are replaced verbatim, nil included (`Context#override`): a nested
  child's `from`-less transition never inherits the parent step's `from`,
  and the failed `:transition` trace keeps `from`/`to` present even when
  nil for the same reason.
- Merge ambient attribution fields into every `Smith::Trace.record` payload.
  Attribution keys are identifiers, not content: caller-supplied keys win on
  conflict, the content policy is unaffected, and a configured
  `trace_fields` allowlist stays authoritative (add attribution keys to an
  allowlist to receive them). Disable with `Smith.config.trace_attribution =
  false` (default true).
- Bound `Smith::Trace::Memory` (default 10,000 entries) with a
  `dropped_count` reader and a `snapshot` method for readers racing
  concurrent recording.
- Tag `Workflow::UsageEntry` with the ambient attribution at recording time:
  new optional members `transition`, `branch_key`, `round`, and `attempt_id`.
  All four are nil on entries restored from checkpoints written by earlier
  Smith versions and are omitted from serialization when nil, so restored
  pre-attribution documents re-serialize byte-identically (hosts that digest
  whole persisted documents in exact-mutation proofs depend on this). A
  rolled-back gem drops the new keys from plain checkpoint payloads
  (`from_h` slices to known members). Composite branch effects are the
  exception: effects written by this version from a fan-out branch carry
  real attribution values, and an older gem's exact-key effects validation
  rejects them, so see the upgrade notes below before rolling back.
  `recorded_at` now carries microsecond precision (`iso8601(6)`) on new
  entries. Recording symbolizes `transition`/`branch_key` Strings exactly
  as `from_h` does on restore, so a host seeding String attribution through
  `Smith::Attribution.with` gets entries equal to their restored form.
- Measure each provider attempt with a monotonic clock around the whole chat
  completion (including any provider tool loop) and emit one
  `:provider_call` trace per attempt (success or failure) carrying `model`,
  `provider`, `duration_ms`, `attempt_id`, `attempt_index`, and `outcome`.
  Every usage entry the attempt produced shares its `attempt_id` (an attempt
  with an N-round tool loop records N entries): join there for the attempt's
  single duration, never sum across entries. Gate with
  `Smith.config.trace_provider_calls` (default true). `ProviderAttempt`
  gains optional `attempt_id` and `duration_ms`.
- Add a public read-only `Workflow#usage_entries` (frozen copy under the
  recording mutex) so hosts can diff usage across a step boundary without a
  full `to_state` serialization; `to_state` and `snapshot_usage_entries` now
  read the ledger under the same mutex, so a state written mid-fan-out never
  captures a torn array.
- Thread real correlation identity through events: `Smith::Event#execution_id`
  and `#trace_id` default to the ambient attribution execution key (the
  persistence key during persisted runs) instead of a fresh random UUID per
  event; the random fallback remains for events built outside any execution
  scope. The `:tool_call` trace gains a nullable `tool_call_id` when the
  invocation came from a provider batch (the tool-results capture entry
  gains the same key under a later bullet in this release; composite
  effects accept the extended shape with bounded value validation).

- Emit from the step-failure paths, closing the success-only observation
  gap: both `handle_step_failure` and the unresolved-transition handler now
  record a `:transition` trace with `outcome: :failed` plus bounded
  classification (`error_class`, `error_family` from FailureRecord's
  taxonomy, `retryable`) and emit a new `Smith::Events::StepFailed` event.
  Raw error messages never ride either; an emission failure is logged and
  can never mask the original step error. The marker key is `outcome`
  because `result` is a reserved content key in the trace pipeline. An
  unresolved transition with no `:fail` transition still re-raises without
  emitting: that path was never treated as a step. The unresolved handler
  runs outside any step context, so it seeds the run identity explicitly;
  both failure paths stamp persisted-run events with the persistence key.
  Emission is terminal-per-step: a step that retries internally and then
  succeeds emits only its `StepCompleted`; intermediate step-body retry
  attempts stay dark at the step layer (provider-level failures remain
  visible as `:provider_call` failure traces). `StepFailed` handlers run
  outside the step snapshot's interrupt-masked region (emission is staged
  in the failure rescue and flushed after the mask closes), interruptible
  exactly like `StepCompleted` handlers. A step body that surfaces Smith's
  own `UnresolvedTransitionError` emits exactly one `StepFailed` under the
  real step identity; the unresolved handler recognizes the already-emitted
  error instead of emitting a second event under the requested (never
  executed) name.
- Emit the long-advertised `:cost` trace: one per completed agent
  invocation, whose value is the sum of that invocation's per-response
  usage-entry costs. Summing per response is what tiered catalogs actually
  bill; pricing the aggregate token totals as one call would resolve the
  wrong tier for multi-response tool loops. Emitted only for fully metered,
  fully priced invocations (a partially priced or partially metered
  invocation emits nothing rather than presenting an incomplete figure);
  gated by the existing `trace_cost` setting (the per-type gates live in
  the built-in adapters; a custom adapter receives every type). `:cost`
  traces are not a spend total: billed failed and partial attempts appear
  only in usage entries. The same per-response sum now becomes
  `agent_result.cost`, so budget settlement, result surfaces, recorded
  entries, and the trace all agree on one invocation cost.
- The OpenTelemetry adapter now creates retroactive spans with real
  durations (span start backdated by `:tool_call` seconds or
  `:provider_call` milliseconds; instant spans otherwise), preserves
  numeric attribute types instead of stringifying everything, and uses only
  the documented opentelemetry-api surface (`Tracer#start_span` with
  `start_timestamp`, `Span#finish` with `end_timestamp`).

- Add a `workflow` discriminator to the ambient attribution, every trace
  payload, usage entries, and the `StepCompleted`/`StepFailed` events: the
  emitting workflow's class name ("anonymous" when unnamed), so
  nested-child graph facts are distinguishable from parent facts under the
  shared root execution identity. Nil-omitted from serialized entries like
  the other attribution members.
- Every provider attempt now emits its `:provider_call` trace: `outcome` is
  `:success`, `:failure` (provider failure, fallback may continue), or
  `:aborted` (a non-provider error that re-raises), so prefix-accounted
  usage entries always have their attempt join target.
- The tool-results capture entry gains `tool_call_id` when the invocation
  came from a provider batch (omitted otherwise, so direct-invocation and
  pre-existing payloads keep their exact two-key shape); composite effects
  accept the extended shape while still rejecting unknown keys.
- `StepFailed` handlers now run outside the step snapshot's
  interrupt-masked region: emission is staged in the failure rescue and
  flushed after the mask closes with explicitly seeded run identity, so a
  slow host handler can no longer make the workflow thread unkillable and
  handlers match `StepCompleted`'s interruptibility.

### Fixed

- A user-declared `:fail` transition no longer inherits the early order
  position of the auto-generated placeholder created by `state :failed`:
  redeclaring a generated transition takes a fresh declaration position, so
  it can no longer shadow a same-origin primary transition at run time.
  Genuine user redefinitions keep their original position, and subclasses
  inherit the bookkeeping.
- Budget cost settlement now consumes the per-response priced sum instead
  of pricing the invocation's aggregate token totals. Under linear pricing
  the figures are identical; under tiered pricing the aggregate resolved
  the wrong tier (or missed every tier and settled zero), so a
  cost-budgeted workflow could keep spending after its real billed cost
  exceeded the budget.

### Removed

- Remove the never-read `trace_retention` and `trace_tenant_isolation`
  settings. Both were silent no-ops since introduction; reading or writing
  them now raises, so a host relying on the illusion fails loudly instead
  of silently.

### Changed

- Workflow step failure is now observable: subscribers to the events bus
  receive `StepFailed` where previously failures emitted nothing (the
  success-only scope is gone), and trace consumers see failed `:transition`
  payloads distinguished by `outcome: :failed`.
- `Workflow::Composite::Effects` validates usage-entry keys as
  required-plus-allowed instead of exact: entries from an older producer
  (missing the optional attribution keys) stay valid, current entries with
  attribution pass, and unknown keys still reject. The optional keys are
  bounded values, not just bounded keys: `transition`, `branch_key`, and
  `workflow` must be non-empty Strings up to 256 characters, `round` a
  non-negative Integer, and `attempt_id` a UUID when present. Tool results
  accept the extended capture shape: `tool_call_id`, when present, must be
  a non-empty String up to 1024 characters (`tool` keeps its exact prior
  validation).


- `Smith::Events` subscriptions now live in per-class buckets guarded by a
  mutex: emit touches only the buckets for the event's ancestors instead of
  scanning every subscription, dispatch order remains registration order,
  and `is_a?` matching semantics are unchanged (instance-extended modules
  dispatch through the singleton class; immediate values, which have no
  singleton class and cannot be extended, dispatch through their class
  ancestors). `Subscription#cancel` now
  detaches from the registry, so cancelled subscriptions (including
  `Events.within` scopes) no longer leak. Handlers run outside the registry
  lock, so a handler may subscribe or cancel without deadlocking.
- `Smith::Trace::Memory#record` and `#clear!` are mutex-guarded and safe
  under parallel fan-out branches.

## [0.8.0] - 2026-07-25

### Added

- Add opt-in graceful agent tool-budget exhaustion with a finite
  `tool_calls` budget and `tool_budget_exhaustion :complete`. Smith consumes
  model-requested calls atomically, rejects oversized batches without partial
  execution, pairs every rejected call id, and performs one tool-disabled final
  completion.
- Add one-use call admissions so an admitted Smith tool is not double charged,
  while exact tool identity prevents nested tools from stealing an admission.
- Aggregate trustworthy token usage across every assistant response in a
  successful RubyLLM tool loop, record one durable usage entry per provider
  response, and preserve completed-prefix usage when a later provider round
  fails.
- Expose immutable normalized tool-call metadata and one execution-scoped,
  host-seedable invocation sequence across Smith-managed chats, branches,
  threads, and fibers without introducing host persistence semantics.
- Add immutable exact tool-call budgets with aggregate and per-tool limits for
  host-controlled execution scopes.
- Add a host-neutral whole-batch admission callback and per-invocation dispatch
  failure callback. Smith snapshots immutable requests, admits the complete
  Smith-managed subset of the provider batch before dispatch, and never reports
  failure for a batch whose host admission callback raised.
- Add a Claude 5+ family inference rule: Fable, Mythos, Opus, Sonnet, and Haiku
  ids with major version 5 or higher resolve to adaptive thinking, no
  temperature accepted, and native tools-with-thinking, so an agent-declared
  `temperature` is stripped instead of being sent to a provider that rejects
  it. Dotted 4.x ids (for example `claude-haiku-4-5`) keep matching the 4.x
  budget-tokens rule.
- Add new public error classes hosts may rescue or allowlist:
  `Smith::PricingConfigurationError`, `Smith::ProviderPermanentFailure`
  (carries `provider`, `model_id`, and `source_error_class`),
  `Smith::Models::AmbiguousProfileError`, `Smith::Models::CollisionError`,
  `Smith::ToolDispatchRejected`, `Smith::ToolOutcomeUncertain`,
  `Smith::ToolExecutionNotAdmitted`, `Smith::ToolFailureNotificationFailed`,
  `Smith::BoundedCompletionError`, and `Smith::PersistedFailureInvalid`.
  Terminal tool-evidence families surface through
  `Smith::Errors.retry_forbidden?` / `retry_forbidden_class?` and must never be
  retried by host jobs.
- `Smith::Doctor` reports a dedicated failing `models.ambiguity` check when a
  registered agent declares an unqualified model id registered under multiple
  providers, instead of aborting the run with `AmbiguousProfileError`, and now
  validates the assigned pricing catalog (legacy model-only keys, malformed
  entries, and colliding keys fail the `config.pricing` check).
- Capture the causal failure classification behind an uncertain tool outcome
  into the durable failure record: a persisted `Smith::ToolOutcomeUncertain`
  carries bounded `error_cause_class`, `error_cause_family`, and
  `error_cause_message` from its cause so a restored host can distinguish a
  deadline, cancellation, or defect. The three attributes travel as one unit;
  legacy records omit all three, and a partial or unknown-family set fails
  closed at state admission.

### Changed

- Bump `Smith::EXECUTION_SEMANTICS_VERSION` from `3` directly to `5` for exact
  per-tool budgets, shared composite admission, bounded graceful completion,
  and cumulative tool-loop usage. The value `4` was consumed transiently during
  development of this slice and is intentionally skipped so a composite plan
  persisted against an interim build can never read as compatible with the
  released semantics; consumers compare by exact equality, so every pre-`5`
  plan is invalidated either way.
- Key model profiles, fallback candidates, usage telemetry, and pricing by exact
  provider/model identity. Provider-qualified pricing never falls back to a
  legacy model-only rate, and fallback declarations must name their provider.
- Let observation masking preserve the exact immutable seed-message prefix
  while bounding only later workflow observations. The prefix length is
  persisted and validated across restart; legacy state defaults to zero.
- Require the exactly qualified RubyLLM `1.16.0`; graceful completion is
  isolated behind that verified chat interface and fails closed on incompatible
  hooks. Future RubyLLM versions require an explicit compatibility pass.
- Enforce the pricing-catalog key policy at admission time instead of inside
  accounting: `Smith::Pricing.validate_catalog!` rejects legacy model-only
  keys, unrecognized key shapes, malformed entries, and post-normalization
  collisions, and the doctor runs it against the assigned catalog.
  `Pricing.compute_cost` itself never raises: a provider-qualified lookup reads
  only provider-qualified entries and returns nil (visibly unpriced) when only
  a legacy rate exists, so an in-flight accounting path can never mask a
  provider error with a pricing configuration error.
- Registering a model profile whose capabilities differ from the profile
  already registered for the same provider/model identity now raises
  `Smith::Models::CollisionError`; earlier releases silently replaced the
  profile on Rails reload. Re-registering a value-identical profile stays
  idempotent (see Migration notes).
- `Smith::Models::Normalizer` tool/endpoint routing no longer requires active
  thinking: endpoint compatibility is evaluated on every chat construction, the
  endpoint preserving the strictly larger compatible tool subset wins (ties
  keep the current endpoint; a single forced tool that only one endpoint can
  carry takes precedence), and each dropped tool records a `:tool_dropped`
  decision. See docs/TOOLS_AND_GUARDRAILS.md.
- Agent tool evidence is tracked per transition: once any tool starts inside a
  transition, a later provider failure in that transition (including one from a
  concurrently executing parallel branch that never ran a tool itself) refuses
  model fallback and surfaces `Smith::ToolOutcomeUncertain`. This is
  deliberately conservative and fail-closed; branch-scoped evidence that
  restores fallback for provably tool-free sibling branches is planned, and
  child-workflow tool evidence does not yet mark the parent transition.
- `from_state` failure-record problems raise `Smith::PersistedFailureInvalid`
  while other persisted-shape problems keep raising
  `Smith::SerializationError`; both descend from `Smith::Error`, and hosts
  rescuing `SerializationError` around restore must handle both.
- Restored failure records no longer resolve or construct arbitrary error
  classes named by persisted data: host-defined subclasses reconstruct as their
  Smith family parent (family `"other"` restores as `RuntimeError`), so
  exact-class matching against restored `last_error` values must move to family
  or `is_a?` checks.
- `Smith::Agent.fallback_models` now returns a frozen array of
  `Smith::Agent::ModelReference` values (previously raw strings), block-form
  `model {}` declarations must return a provider-qualified reference (a bare
  string raises `Smith::AgentError`), permanent provider failures raise
  `Smith::ProviderPermanentFailure` instead of a retryable `AgentError`,
  non-provider `StandardError`s raised inside a provider attempt now propagate
  raw instead of being wrapped, and `Workflow::UsageEntry` is frozen and gained
  a `:provider` member.

### Fixed

- Preserve the provider and model actually selected by RubyLLM in completion
  usage, keep inherited fallback configuration immutable, and treat model-level
  permission failures as model scoped so an eligible fallback on the same
  provider remains available. Only account-wide authentication and payment
  failures suppress later candidates from that provider.
- Prevent unavailable provider tool calls from creating an unbounded correction
  loop by consuming the model-request allowance before dispatch.
- Prevent fallback-model restart after a Smith tool begins executing, because a
  fresh chat would discard tool evidence and violate the provider protocol.
- Prevent transition retry, including broad explicit retry classes, when any
  later provider, completion hook, output validation, or guardrail failure occurs
  after a bound tool dispatch makes the external outcome uncertain.
- Reserve provider batches atomically against both the agent allowance and the
  effective workflow tool budget, then reconcile unexecuted calls.
- Execute bounded tool loops iteratively so finite call allowances do not grow
  Ruby stack depth, reject concurrent or callback reentry on one bounded chat,
  and retain RubyLLM's native forced-tool-choice reset.
- Validate `Smith::Tool#perform` keyword arguments before budget charge and tool
  execution, reject non-Smith bindings from the opt-in bounded policy, and fail
  closed when raw provider params try to override reserved tool controls.
- Keep provider-facing tool controls and RubyLLM instrumentation aligned, and
  restore tools, call preferences, and concurrency after success or failure.
- Permit bounded providers to return multiple calls in one response while more
  than one call remains. Smith retains atomic batch reservation, deterministic
  sequential execution, and fail-closed oversized-batch handling.
- Propagate one enclosing tool-call allowance into same-agent parallel and
  heterogeneous fan-out worker threads so branches cannot multiply a host's
  signed transition budget.
- Materialize one immutable admitted dispatch batch before host admission, so
  later mutation of the provider collection, call identity, or arguments cannot
  alter which Smith tools execute or the values they receive. The host callback
  receives immutable source-call evidence while RubyLLM dispatches a separately
  owned admitted call, and an atomic dispatch claim prevents callback re-entry
  from executing the same admission twice. Continue to reject registered-tool
  replacement and classify only guaranteed pre-`perform` failures as
  `ToolDispatchRejected`.
- Capture provider batches with native `Hash` operations, bound the complete
  provider batch to 100 calls and 1 MiB of UTF-8 call metadata, reject malformed
  call protocol before host admission, and stop aggregate metadata capture as
  soon as the bound is crossed.
- Bound immutable argument copying before child allocation, account for expanded
  serialized occurrences even when a caller reuses a shared object graph,
  admit each mutable container's native size before one shallow copy, verify the
  copy retained that size before child allocation, reject hostile container
  overrides and malformed UTF-8, and keep traversal iterative with linear time
  and bounded space.
- Require one exact execution authority for every managed Smith tool dispatch.
  Direct tool calls from provider callbacks and nested Smith tool calls now fail
  closed; nested execution requires a future separately admitted primitive.
- Give terminal tool-evidence failures precedence during parallel arbitration
  and centralize their non-retryable classification across declaration and
  execution. Persist and restore terminal notification failures without resolving
  or constructing arbitrary classes named by persisted data. Bound and normalize
  failure diagnostics, capture failure class identity with native Ruby operations,
  and reject inconsistent family/retry metadata or malformed typed failure details
  at state admission.
- Cover the split execution files with direct-load contracts so each new file
  loads standalone; the released artifact's file manifest is verified against
  `lib/` at release time as part of the release procedure.
- Fail closed with a typed `Smith::AgentError` when an agent has no executable
  model candidate (empty model chain), instead of leaking the exhausted
  candidate sequence into nil destructuring from optimizer and orchestrator
  paths.
- Attribute an account-wide authentication or payment failure to the attempted
  reference's declared provider when the chat is unobservable, so a dead
  provider account is not billed a second same-provider attempt.
- Deduplicate model candidates by physical identity, so a provider-unqualified
  primary and a provider-qualified fallback naming the same model cannot
  produce a duplicate attempt, and `ModelReference.coerce` now parses the
  `"provider/model"` string form that `#to_s` emits (the first slash splits, so
  slashed model ids round-trip).
- Keep captured and restored failure records symmetric for blank messages:
  capture substitutes a deterministic placeholder for a blank error message, so
  a workflow state whose last failed step had an empty message restores instead
  of raising `Smith::PersistedFailureInvalid` and poisoning crash/resume.
- Restore legacy failure records whose `error_message` exceeds the 64 KiB
  diagnostic bound by truncating exactly as capture truncates, instead of
  rejecting the persisted workflow state for message length alone; non-text and
  invalid-UTF-8 persisted values still fail closed.
- Scope an agent `tool_calls` budget under a legacy Hash tool-call allowance to
  a typed rejection at both call sites instead of an untyped `NoMethodError`
  mid-transition.
- Propagate a settled or exhausted batch reservation's refusal through
  `CallAdmission#claim`, so a post-settlement execution can never run against
  an already reconciled ledger.
- Keep a queued process-fatal sibling error ahead of a
  `ToolFailureNotificationFailed` raised while notifying unsettled batch
  failures, so notification problems cannot mask fatal arbitration outcomes.

### Migration notes

- Pricing catalogs must move to provider-qualified keys (`%w[provider model]`
  arrays or `"provider/model"` strings). Legacy model-only keys still price
  provider-unqualified usage for compatibility, but they fail
  `Smith::Pricing.validate_catalog!` (now run by the doctor), and
  provider-qualified usage never reads them: such usage records nil cost until
  the catalog is qualified.
- `fallback_models` entries must name their provider (`"provider/model"`, a
  Hash, or a `ModelReference`); bare model ids fail closed at class definition.
- Hosts registering `Smith::Models` profiles from reloadable code must move
  registration to boot-once initializers or restart after editing a profile;
  value-different re-registration now raises `Smith::Models::CollisionError`.
- The gem now requires exactly `ruby_llm 1.16.0` (previously `>= 1.15,
  < 1.17`); hosts on 1.15.x must upgrade together with this release.
- Hosts that rescued `Smith::AgentError` for permanent provider failures should
  rescue `Smith::ProviderPermanentFailure`, and restore-time rescues of
  `Smith::SerializationError` must also handle
  `Smith::PersistedFailureInvalid`.

## [0.7.0] - 2026-07-21

### Added

- Add an opaque host invocation context for tool adapters, propagated through
  Smith parallel/fan-out branches and concurrent tools on individual chats
  created by `Smith::Agent` without globally changing RubyLLM behavior. Durable
  workers receive it only when the host installs a fresh process-local context.
- Add opt-in strict tool-result capture with typed failure diagnostics and
  persistence-safe reconstruction.

### Changed

- Bump `Smith::EXECUTION_SEMANTICS_VERSION` to `3` because composite branch
  failure transport now preserves strict tool-capture uncertainty and its
  typed tool metadata across persistence.
- Support RubyLLM `>= 1.15, < 1.17`; Smith's per-chat concurrent tool context
  integration is verified against those execution interfaces and fails closed
  when the required chat hook is unavailable.

### Fixed

- Make agent tool-call allowance atomic across concurrent tool calls.
- Install Smith's tool execution boundary on direct and persisted agent chat
  entry points (`chat`, `create`, `create!`, and `find`) without modifying raw
  RubyLLM chats globally, and capture invocation context independently for each
  tool execution batch.
- Give strict capture uncertainty precedence over sibling concurrent failures,
  reject unusable collectors before host hooks or tool execution, and prevent
  transition retries from replaying an uncertain tool outcome.
- Preserve process-fatal failures across concurrent tool callbacks and root
  workflow branches regardless of sibling completion order.
- Reject malformed or future strict-capture diagnostics at persistence
  boundaries, while preserving legacy non-capture composite error transport.
- Preserve the existing per-concrete-class `capture_result` opt-in behavior and
  the public `BranchEnv` member shape.

## [0.6.1] - 2026-07-20

### Fixed

- Persist a composite transition's execution namespace with its prepared
  split-step snapshot so prepared- and dispatch-state recovery reproduce the
  exact same plan.
- Pin composite namespace preparation to Smith-owned implementations so
  subclass method collisions cannot bypass durable plan identity, and release
  the preparation claim cleanly when namespace generation fails.

## [0.6.0] - 2026-07-20

### Added

- Add a host-neutral durable composite lifecycle for same-agent parallel and
  heterogeneous fan-out transitions. Smith emits immutable bounded plans and
  inputs, executes one authorized branch through captured agent bindings, and
  deterministically reduces a complete ordered outcome set through the normal
  transition completion and failure paths.
- Add exact transport contracts for ordered branch descriptors, redacted branch
  failures, usage/tool/budget effects, and host-committed primary failure
  selection. Composite branch retries remain explicitly unsupported; hosts own
  scheduling, persistence, claims, fences, and incomplete-branch resumption.
- Add compact selected-branch execution envelopes and stable host-declared agent
  execution identities so workers do not receive the full plan and registry
  replacement after planning fails closed.
- Add scoped prepare, selected-branch execution, and reduction entry points so
  process-local authority never crosses the supported public composite API.

### Changed

- Bump `Smith::EXECUTION_SEMANTICS_VERSION` to `2` so hosts invalidate generated
  executable definitions when adopting the composite lifecycle.
- Canonicalize aggregate branch output to the same JSON-compatible shape before
  and after persistence.

### Fixed

- Preserve complete workflow, agent, and branch execution context across
  nested parallel and heterogeneous fan-out work without leaking thread- or
  Fiber-local Smith state.
- Keep ordinary subclass setup and teardown extension points intact while
  prepared execution seals framework-owned branch dispatch against subclass
  replacement.
- Restrict prepared execution authority to the exact coordinator or registered
  branch Fiber, reject copied or serialized process-local authority, and make
  activation, cleanup, and context restoration safe against asynchronous Ruby
  thread interruption.
- Keep composite planning and full-run validation linear in branch count, make
  individual branch binding capture and validation constant-time in branch
  count, reject the hard transport ceiling before descriptor allocation, and
  incrementally enforce cumulative effect/output envelopes before consuming
  execution authority.
- Isolate decimal aggregation from host `BigDecimal` precision, reject aggregate
  usage overflow, and preserve composite branch identity and retry
  classification across persistence.
- Bind one artifact execution namespace into every branch and the reducer,
  reject aggregate budget overrun and known usage replay before consuming
  authority, and validate cumulative persisted token/cost accounting.
- Enforce complete canonical payload fields and encoded JSON byte limits before
  returning transport values.
- Allocate disjoint branch budget envelopes without exceeding the parent,
  reconcile usage against branch-local token/cost consumption, bind branch
  authority to one exact execution envelope, and prevent subclass collisions
  from bypassing durable dispatch verification.
- Reject forged retryability, untrusted error metadata, and unknown transport
  keys without symbol interning; validate scalar and replay failures before
  snapshotting tool effects.
- Reject unknown transport enum values without symbol interning, reject corrupt
  persisted branch-failure evidence instead of inventing defaults, enforce
  cumulative encoded-effect bounds while streaming outcomes, and close active
  branch authority before asynchronous interruption can escape a scoped call.

## [0.5.0] - 2026-07-19

This release contains intentional pre-1.0 public contract tightening and is a
minor release rather than a `0.4.x` patch.

### Added

- Add configurable per-execution parallel branch/concurrency limits and a
  shared finite exponential-backoff contract for workflow and persistence
  retries.
- Keep nested fan-out inside one bounded execution context across Fiber
  boundaries, inherit outer cancellation, use only idle top-level workers, and
  drain already-running branch work rather than detaching work or forcibly
  killing threads with live resources. Add a configurable nesting limit,
  hard-capped at 256, so recursive host composition fails before Ruby stack
  exhaustion.

- Add bounded host-coordinated session-message admission through
  `Workflow#append_session_messages!`. Smith owns a canonical immutable copy,
  serializes append against workflow execution, and returns an immutable
  `MessageAdmission` digest witness while leaving persistence, idempotency,
  session identity, and resume policy with the host.
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
- Add a generic process-local prepared-step execution authorization. Smith
  verifies an exact preparation or dispatch without performing transition work;
  a host may then commit its own executing-attempt record before consuming the
  non-copyable, process-bound capability exactly once. Standard Marshal,
  Psych/YAML, and JSON serialization hooks reject the capability.
- Add `PreparedStepExecutionResult` so hosts can distinguish successful and
  failure-routed transition attempts without inferring success from workflow
  state.
- Add strict bounded `PreparedStep.deserialize` transport decoding and the
  typed `Sha256Hex` scalar. Prepared step counters are constrained to positive
  signed 64-bit values for both Hash and JSON transports.

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

- Make budget settlement receipt-based and one-shot. Reservation, reconciliation,
  and release now fail closed on cross-ledger, replayed, unknown-dimension, or
  amount-only settlement and publish aggregate state atomically. This tightens
  the pre-1.0 ledger API and requires the next minor release.
- Define budget scalar inputs as finite, non-negative `Integer` or `Float`
  values and use exact internal decimal arithmetic so ordinary Float budgets do
  not strand receipts or reject mathematically valid capacity. Ledger snapshots
  remain JSON-safe numerics. This intentionally rejects opaque custom numeric
  objects and non-JSON-safe numeric types at the boundary. Budget arithmetic is
  isolated from and restores any host-configured `BigDecimal` precision limit;
  `bigdecimal` is now an explicit runtime dependency.
- Reject repeated or mixed primary transition declarations instead of silently
  replacing an earlier execution primitive.
- Treat named transition target-origin mismatches as graph errors rather than
  warnings because runtime cannot execute the declared route from that state.
- Constrain workflow topology identifiers to non-blank String or Symbol values,
  matching runtime lookup, event, persistence, and graph-inspection semantics.
- Reject oversized static fan-out declarations, non-finite or unschedulable
  retry delays, and retry attempt counts above the configurable default limit
  of 100 before executable work begins. This intentionally tightens previously
  unbounded pre-1.0 declarations; hosts that require a higher finite attempt
  bound must configure it before loading workflow classes.

- Restore persisted workflow state without mutating caller-owned nested outcome
  data while preserving Smith's symbolized runtime outcome contract.
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
  seal it on the workflow class when preparation or recovery authority is
  acquired. Concurrent digest setters linearize before sealing or fail before
  claim and execution.
- Make Active Record exact replacement one conditional SQL update over key and
  byte-exact payload while incrementing its optimistic-lock column. Validate
  the database primary key or an unconditional single-column unique key index
  through Active Record's table-keyed schema cache before each exact write.
- Resolve callable Redis command clients as clients rather than factories, and
  require a native reconnect-disabling scope before any Redis CAS begins.
- Treat a persistence identity as available in doctor diagnostics only when its
  value satisfies the same bounded non-empty contract used at runtime.
- Revalidate workflow definition and transition identity when an execution
  authorization is consumed. Capability release and execution are linearized by
  exact identity so concurrent or stale holders cannot revoke or replay work.
- Route an active prepared execution through a Smith-owned private-method
  membrane, including reachable nested workflows. Subclass overrides retain
  normal Ruby dispatch outside the authorized boundary but cannot substitute
  retry, dispatch, guardrail, budget, or completion behavior during it. Nested
  authority is limited to the root execution thread and revoked when that
  execution closes, even when a host retains a child workflow instance.
- Own String workflow identifiers at declaration time and keep graph snapshots
  isolated from mutable caller aliases. Reject other topology object types at
  the DSL boundary so graph lookup, event, and persistence semantics remain
  consistent. The authorized
  completion and failure boundaries bind Smith's implementation directly so
  subclass method-name collisions cannot bypass typed result capture.
- Capture exact direct, fan-out, optimizer, orchestrator, and reachable nested
  agent bindings during authorization with bounded `O(V + E)` traversal. Later
  mutable registry replacement cannot alter the authorized execution.
  Same-agent parallel execution resolves its captured binding on the authorized
  root thread and passes an identity-scoped class reference into worker
  branches without leaking it into re-entrant workflows on the same thread.
- Replace recursive graph reachability with an iterative walk over a graph-local
  outgoing index. Existing graph snapshots remain isolated from later workflow
  class mutation. State-reference validation and terminal-state metrics use
  constant-time graph indexes. Nested runtime-readiness inspection uses an
  iterative postorder traversal with workflow-class identity memoization and
  cycle-edge diagnostics. Nested workflow contracts are captured and
  revalidated before and immediately after child construction without repeated
  full-transition scans.
- Bound durable preparation comparison by canonical payload byte and node
  limits, and preserve the legacy mutable step Hash while typed execution
  results own an immutable, cycle-aware, bounded JSON-like snapshot. Result
  validation now completes before successful workflow state mutation; invalid
  provider output enters normal failure routing and returns a typed failure.
  Hash keys are limited to owned String or Symbol values, and non-finite Floats
  are rejected before success mutation.
- Normalize top-level string keys in restored message Hashes before rebuilding
  RubyLLM messages. Nested message content remains untouched so transport
  decoding does not rewrite host payloads.

- Maintain a declaration-time outgoing-transition index. First-transition and
  terminal checks are constant-time; enumerating transitions from one state is
  proportional to that state's outdegree. Stable declaration precedence,
  subclass isolation, and transition redefinition semantics are preserved.
- Custom adapters that report an open transaction now require
  `transaction_identity` for strict split-step preparation. This intentionally
  tightens the 0.4.5 boolean transaction contract so later unrelated
  transactions cannot re-authorize a rolled-back descriptor.

### Verification

- Default suite: 1,304 examples, 0 failures on the final tree.
- Runtime-hardening practical suite: 551 scenarios and 33,722 assertions across
  graph reachability, retry/backoff, nested parallel execution, cancellation,
  receipt-based budgets, hostile decimal precision, and asynchronous thread
  interruption.
- The built gem and its declared dependency set loaded under Ruby 3.2.2 and
  Ruby 3.2.8; each runtime passed the same 551-scenario practical suite.
- Downstream verification against the local checkout: Smith Runtime passed
  1,188 runs and 6,287 assertions with 35 skips, plus 20 practical scenarios;
  Smith Studio passed 1,848 runs and 13,851 assertions with one skip, plus 20
  practical scenarios.
- Message-admission and restore-input suite: 30 examples, 0 failures. A
  44-scenario public-API matrix covered canonicalization, alias isolation,
  bounded rejection, lifecycle contention, persistence round trips, and a
  90,000-value near-limit message.
- Focused graph, execution-authorization, binding-snapshot, typed-result, and
  restored-message suite: 71 examples, 0 failures. All newly added files pass RuboCop;
  the changed surface passes after excluding the repository's pre-existing
  metrics baseline, and `git diff --check` passes.
- Practical gem execution: 30 restart-safe scenarios covering serialized
  preparation and dispatch recovery, exact-claim contention, corruption,
  definition drift, ambiguous acknowledgements, and Active Record
  commit/rollback coordination; a real redis-rb 5.4.1 run additionally proved
  direct-client and factory resolution plus bounded multi-client exact-claim
  contention.
- Practical execution-authorization matrix: 30 public-API scenarios covering
  success and handled failure variants, immutable graph snapshots up to 5,000
  transitions, cyclic and shared result values, bounded rejection cases,
  release, single-use authorization, copying, serialization, and concurrent
  claims.
- Additional practical hardening matrix: 20 public-API checks covering mutable
  topology projection, 1,000/2,000/4,000-transition validation, 5,000-transition
  reachability, a 1,200-workflow nested chain, shared-child memoization, cycle
  diagnostics, root and nested execution membranes, and authorization
  contention. Measured validation times were 5.80 ms, 12.80 ms, and 16.39 ms
  respectively on the local Ruby 4.0.1 verification host.
- A downstream host passed its serial and parallel suites against the
  local Smith checkout and completed its practical direct-model boundary.

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
