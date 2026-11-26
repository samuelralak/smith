# Smith Contract Spec Matrix

This matrix maps the current RSpec contract suite to Smith's public runtime
contracts and architecture notes.

Rule for future spec changes:

1. Every new assertion must be traceable to the architecture document.
2. If the architecture document is ambiguous, the ambiguity should be resolved in the document first or explicitly called out in the spec review.
3. Prefer contract assertions over implementation-coupled assertions.

Interpretation note:

- This matrix records what the spec suite covers.
- Coverage here means "specified by tests," not "currently implemented without failures."
- If a spec exists and currently fails, the contract is still covered here and the failure represents a live implementation drift.

## Coverage Summary

Current contract coverage exists for:

- top-level namespaces and error hierarchy
- top-level configuration surface, including structural-trace defaults and content-tracing opt-in default
- agent inheritance, DSL, registry binding, fail-fast unresolved-agent behavior, and fallback model-chain runtime behavior
- workflow DSL, transition metadata capture, serialization entry points, exact state shape, run-result surface, best-known execution cost aggregation, persisted-context filtering, and configured-adapter durability helper surface
- declaration-indexed outgoing transition lookup and public pending-transition-name inspection, including subclass and transition-redefinition isolation
- static workflow graph inspection and validation reports: read-only transition snapshots, unresolved named-target diagnostics, router target validation, undefined state diagnostics, reachability warnings, graph metrics, fan-out join metadata, optimizer/orchestrator contracts, and runtime readiness reports
- per-agent-call usage facts: `Workflow::UsageEntry` struct shape (14 members: the original 9 plus optional `transition`, `branch_key`, `round`, `attempt_id`, `workflow`), JSON-safe to_h/from_h round-trip with symbol coercion (now including `transition`/`branch_key`, applied identically at recording time so host-seeded String attribution round-trips equal), nil-tolerant restore of pre-attribution checkpoint payloads, `RunResult#usage_entries` field with deep-copy on population, lifecycle recording from completed AND failed-but-accounted attempts via a single mutex critical section, and parallel-fan-out attribution via local-arg `model_used` (no `@last_attempt_model` ivar)
- failure-path observability: `StepFailed` emission from step-body and unresolved-transition failures with FailureRecord classification and run identity on BOTH paths (the unresolved handler seeds identity explicitly because it runs outside step context), bounded transition identifiers, failed `:transition` traces marked `outcome: :failed` (never `result`, a reserved content key) carrying no raw messages, emission-failure isolation (a broken adapter never masks the step error), single-per-invocation `:cost` emission as the sum of per-response entry costs (tiered catalogs price per response; absent when unpriced, gated by `trace_cost`), and OpenTelemetry retro-spans with duration-backdated starts, numeric attributes, and finish-on-attribute-error
- follow-up hardening: deferred StepFailed emission outside the step snapshot's interrupt mask (handlers observe a torn-down step context and seeded identity), the `workflow` attribution discriminator end-to-end (traces, usage entries, both step events, nested parent/child labeling under one root execution key), `:provider_call` for every attempt including `outcome: :aborted` non-provider re-raises, batch-only `tool_call_id` on capture entries with the widened composite tool contract (acceptance with a bounded id, the pre-existing two-key shape, nil/oversized rejection), and generated-`:fail` order release (same-origin shadowing, redefinition position retention, subclass inheritance)
- review-round hardening: per-step attribution replacement (`Context#override`; a child's `from`-less step never inherits the parent's `from`, pinned end-to-end through a nested routed `:fail` on the ambient-only `:provider_call` trace, mutation-verified), exactly-one `StepFailed` when a step body surfaces `UnresolvedTransitionError` (real step identity, never the phantom requested name; mutation-verified against the removed early return), immediate-value event dispatch through class ancestors, `Composite::Effects` bounded value validation for the optional attribution keys (non-String `workflow`, oversized `transition`, non-UUID `attempt_id`, non-Integer `round`, and `false` agent_name all reject; nil agent_name/provider stay valid), budget cost settlement from the per-response priced sum under tiered pricing, `:cost` gating to fully metered fully priced invocations (partial pricing and unmetered responses emit nothing while the partial sum still settles the budget), and OpenTelemetry span finish under a raising `set_attribute`
- serialization stability under upgrade: nil attribution members omitted from `UsageEntry#to_h` so pre-attribution checkpoint documents restore and re-serialize byte-identically (exact-mutation digest proofs in hosts depend on it); extend-based `is_a?` event dispatch preserved via singleton-class ancestors; allocate-safe public `usage_entries` reader
- provider-attempt timing and correlation: one `:provider_call` trace per attempt (success and failure) with monotonic `duration_ms`, `attempt_id`, `attempt_index`, `outcome`, and ambient step attribution; usage entries of one attempt share its `attempt_id`; `trace_provider_calls` opt-out; microsecond `recorded_at`; public frozen `Workflow#usage_entries` reader; `Smith::Event` ids defaulting to the ambient execution key during persisted runs with the random fallback outside execution scope; `tool_call_id` on batch-originated `:tool_call` traces and its absence on direct invocations; `Composite::Effects` required-plus-allowed usage-entry key contract (legacy entries pass, attribution entries pass, unknown keys reject, missing required keys reject)
- ambient execution attribution: `Smith::Attribution` overlay/restore semantics (nil overrides ignored, raise-safe restore, thread isolation, frozen contexts), per-step installation with the persistence key as `execution_key`, host seeding around non-persisted runs, cross-thread carriage into fan-out branches with branch-key overlay, per-round overlay inside evaluator-optimizer loops, trace payload merging with caller-key precedence, `trace_attribution` opt-out, and `trace_fields` allowlist authority over attribution keys
- observability primitive safety: `Smith::Events` cancellation detaches from the registry (no scoped-subscription leak), ancestor-bucket dispatch preserves registration order and `is_a?` semantics, self-cancellation inside a handler does not deadlock, concurrent registration/emission/cancellation converges; `Smith::Trace::Memory` bounded recording with dropped-entry accounting, consistent snapshots, and parallel-writer safety
- bounded graceful tool completion over the qualified RubyLLM 1.16.0 interface:
  iterative provider rounds, exact allowance exhaustion, unavailable-call
  accounting, all-or-nothing agent/workflow batch admission, unused workflow
  reservation reconciliation, exact-tool admissions, pre-execution `perform`
  argument validation, forced-choice restoration, long-loop stack safety,
  chat concurrency/reentry rejection, non-Smith binding rejection, terminal
  post-tool fallback/retry classification, completed-prefix usage on failure,
  one immutable provider-batch capture, complete-batch cardinality and metadata
  bounds, native-container resistance to hostile overrides, expanded shared-DAG
  argument accounting, coherent native container snapshots, UTF-8 metadata
  normalization, fail-early aggregate metadata bounds, atomic one-effect dispatch
  claims, exact managed execution authority, nested/direct execution rejection,
  linear unsettled receipt settlement, and execution-error precedence over
  settlement or logger failure
- nested-workflow usage rollup: child `total_cost` + `total_tokens` + `usage_entries` rolled up into parent BEFORE the failed-step check raises (preserves failed-child accounted work on the parent), with deep-copied entries via `from_h(snapshot_value(...))` so child and parent are fully independent
- terminal-restore correctness for `RunResult#output` / `#last_error` / `#failure_detail`: persisted `@last_output` and class-aware `@last_failed_step` snapshot drive synthesis when steps are empty on terminal-restore, with backward compat for pre-patch state and value-symbol coercion that matches fresh-run shape
- usage-aware durability peek API: `Workflow.persisted_state_exists?` (fast key-presence check) and `Workflow.restorable_billing_state?` (only true when restored state has at least one `usage_entries` entry — distinguishes Smith's bare initial-state persist from preserved accounted work)
- tiered model pricing in `Smith::Pricing.compute_cost`: flat shape unchanged, tiered shape with `tiers: [{max_input_tokens, input_cost_per_token, output_cost_per_token}, ...]` walked in order, nil `max_input_tokens` as unbounded, both string and symbol keys
- Smith model capability registry, provider-family inference rules, capability-aware normalizer, and direct doctor coverage for registered agent model-shaping gaps
- workflow pattern namespaces
- artifact namespace, top-level accessor, configured-store resolution, built-in backend entry points, and named operational methods
- artifact lifecycle behavior, including opaque refs, per-store isolation, and namespace-prefixed refs
- guardrail base DSL, attachment points, and built-in URL verifier namespace
- guardrail runtime ordering, blocking, and failure-routing surface
- event bus surface, filtering, scoped subscriptions, typed event schema declaration with runtime correlation values, subscription lifecycle behavior, direct dispatch ordering/rescue semantics, and typed workflow success-only event emission surface
- budget ledger surface with denied-reservation, lower-actual reconciliation,
  multi-dimension behavior, exact decimal accounting, and isolation from a
  host-configured `BigDecimal` precision limit
- context manager DSL, stored runtime configuration, subclass inheritance behavior, persisted-key serialization contract, and workflow seed-message initialization surface
- tool base class, policy DSL, runtime execute-to-perform delegation, capability metadata declaration, built-in tool namespaces, and pre-dispatch approval/authorization failure policy boundary
- immutable normalized tool-call metadata, execution-scoped monotonic ordinals
  shared across chats and concurrent thread/fiber dispatch, explicit host resume
  seeding, private framework-owned metadata mutation, and ensure-based scope
  restoration
- persisted terminal tool-notification failure reconstruction, retry-forbidden
  semantics when original classes disappear, bounded JSON-safe failure evidence,
  fail-closed class/family/retry integrity validation, rejection of arbitrary
  persisted constructors, and direct-load coverage for the split execution
  resources
- trace adapter namespaces, runtime transition/tool emission surface, and memory-adapter content policy behavior
- deterministic step primitives (`compute`/`run`): DSL contract, mutual-exclusivity conflict validation (bidirectional for all execution modes), constrained step-object surface, runtime execution (read accessors, write_context with read-after-write coherence via read_context, write_outcome with first-class run-result accessors, route_to with loud failure on unresolved named transitions, fail! with metadata), persistence round-trip, trace lifecycle (started/success/routed/failed plus emitted outcome kind), guardrail boundary enforcement, and mixed agent+deterministic workflow integration
- named transition validation: unresolved named transitions (from route_to, on_success, or any stored next-transition path) fail loudly with WorkflowError
- blank or nil agent completions fail loudly as AgentError-derived runtime failures instead of being accepted as successful step output

Important contracts from the architecture document that are not yet directly specified:

- richer parallel branch merge or provider-style in-flight semantics beyond the current cooperative cancellation and failure/discard surface
- agent-only `token_limit` / `cost` enforcement in serial/helper-owned invocation paths
- any sharper distinction between generic call-boundary deadlines and agent-budget-specific `wall_clock` narrowing
- see Section 4.5 for the narrower remaining budget-specific direct-coverage gaps

## Implementation-Required Areas

These areas still mark the main remaining runtime or integration gaps after the recent artifact, observability, and capability-policy phases. Not every item below requires a new Smith runtime seam; some are now narrower integration or taxonomy gaps.

### 1. Guardrail execution pipeline

Architecture basis:

- Section 4.4, Guardrails
- Section 5.4, Guardrail Attachment

Why more implementation is required:

- The architecture requires synchronous blocking execution for input, tool, and output guardrails.
- It also requires workflow-level guardrails to run before agent-level guardrails.
- Current code now wires workflow-level and agent-level input/output guardrails into workflow execution and routes tool guardrails through workflow/agent-attached guardrails. Workflow-level blocking/failure-routing behavior, tool-boundary retriable failure semantics, and parallel-branch tool-guardrail visibility are covered at the workflow boundary.
- The remaining gap is no longer core guardrail pipeline wiring. It is only any richer end-to-end tool-loop exercising beyond the current workflow-boundary contract surface.

What the implementation agent needs to add:

- richer end-to-end exercising of the tool loop beyond the current workflow-boundary retriable failure coverage

### 2. Event dispatch semantics

Architecture basis:

- Section 4.3, Events

Why more implementation is required:

- The architecture defines dispatch-time guarantees: synchronous inline delivery, rescued/logged handler errors, and subscription-order dispatch.
- Current code includes an event emission/dispatch path with subscription-order dispatch, rescued/logged handlers, and typed emission from BOTH step outcomes: `StepCompleted` on success and `StepFailed` (bounded classification, no raw messages) from both failure handlers. The former success-only scope was removed deliberately (see CHANGELOG Unreleased).
- The built-in event taxonomy remains minimal: `Smith::Events::StepCompleted` and `Smith::Events::StepFailed`.
- Richer semantic event classes are host-defined by default unless explicitly promoted by the architecture later.

What the implementation agent needs to add:

- no additional Smith core event taxonomy by default; only implement more built-in event classes if the architecture is explicitly extended

### 3. Parallel workflow behavior

Architecture basis:

- Section 5.2, Workflow Execution

Why more implementation is required:

- The architecture defines cooperative cancellation, discarding completed branch outputs on failure, and budget cleanup across branches.
- Current code now integrates parallel execution into workflow runtime, routes branch failures through workflow failure handling, performs cancellation checks inside branch execution, runs the same real agent invocation path as non-parallel execution, and covers estimate-based token reservation/reconcile/release, remaining-budget-based branch estimation, and serial/parallel budget settlement.
- The remaining gap is no longer basic parallel budget/runtime wiring. It is limited to richer branch-result or provider-style in-flight semantics beyond the current workflow-visible surface.

What the implementation agent needs to add:

- richer branch-result semantics beyond the current workflow-visible surface
- any provider-style in-flight branch semantics only if the architecture is extended further

### 4. Context/session runtime integration

Architecture basis:

- Section 4.6, Context Manager

Why more implementation is required:

- The architecture defines observation masking at chat runtime and injected-state replacement on retry.
- Current code now exposes a Smith-owned prepared-input seam that performs injection and masking before execution, and workflow execution correctly uses a real RubyLLM `.complete` path over prepared message sets. Injected-state replacement is already covered. The remaining gap is any broader call-path richness beyond the current workflow-driven `.complete` model.

What the implementation agent needs to add:

- any broader call-path richness beyond the current workflow-driven `.complete` seam

### 5. Host-installed host policy integration

Architecture basis:

- Section 5.6, Error Hierarchy
- Section 6, Tool Governance

Why more implementation may be required:

- The architecture explicitly allows host-installed pre-dispatch policy to deny tool execution with `Smith::ToolPolicyDenied`.
- Current tool execution now has a generic `before_execute` pre-dispatch seam, and the suite now covers approval- and network-metadata-driven denial through that boundary.
- The remaining gap is broader host integration guidance or richer end-to-end host wiring, not the core Smith runtime seam.

What the implementation agent needs to add:

- any richer host-integration guidance or end-to-end wiring beyond the existing pre-dispatch tool hook, only if the architecture is extended further

### 6. Artifact host orchestration

Architecture basis:

- Section 4.7, Artifact Store

Why more implementation may be required:

- The architecture requires artifact refs to be namespaced to execution/tenant context.
- Current runtime now supports namespace-prefixed refs, namespace-scoped content-addressed refs, namespace-owned fetch and expired-query behavior in the memory backend, retention fallback, tenant-isolation namespace enforcement, configured-backend artifact handoff refs, and stable execution namespaces across serialization. Remaining artifact gaps are broader host-level orchestration concerns rather than missing store or handoff-runtime seams.

What the implementation agent needs to add:

- broader host-level artifact orchestration only if the architecture is extended further

### 7. Token Usage Tracing

Architecture basis:

- Section 4.8, Observability

Why more implementation may be required:

- The architecture guarantees a built-in `token_usage` trace surface alongside `transition` and `tool_call`, emitted only when both `input_tokens` and `output_tokens` are present and trustworthy. Partial or absent usage metadata does not produce a built-in token-usage trace.
- Current code now includes adapter-level filtering, runtime trace emission for workflow transitions, tool execution, and token usage, built-in logger/OpenTelemetry adapters, capability-aware sensitivity handling, and field-level structural filtering through `trace_fields`.
- All three guaranteed built-in trace types (`transition`, `tool_call`, `token_usage`) are now implemented and spec-covered.
- `cost` remains outside the guaranteed built-in trace surface.

### 8. Cost Tracking Per Execution

Architecture basis:

- Section 4.5, Budget Controller
- Section 5.2, Workflow Execution
- Section 11, Phase 4 Integrations

Why more implementation may be required:

- The architecture now defines `RunResult.total_cost` as Smith's best-known computed workflow subtotal, derived only from trustworthy usage metadata plus a trustworthy pricing source for the execution path used.
- Current code now includes a pricing seam, per-call model-cost computation, best-known subtotal aggregation, nested-workflow subtotal roll-up, and best-effort `total_cost` budget reconciliation when cost is known.
- Built-in cost tracing remains outside Smith's guaranteed trace taxonomy, and richer provider-specific or non-model fees remain out of scope unless the architecture is extended further.

What the implementation agent needs to add:

- richer provider-specific pricing dimensions or non-model fee accounting only if the architecture is extended further

### 9. Fallback Model Chains

Architecture basis:

- Section 5.1, Agent Invocation
- Section 11, Phase 4 Production Readiness

Why more implementation may be required:

- The architecture now defines fallback as an agent-level ordered model chain with Smith-owned transient-failure classification, shared budget/deadline accounting across attempts, and no fallback by default on policy, schema, or guardrail failures.
- Provider-reported model unavailability (`404`/`410`) is fallback-eligible before tool execution, while arbitrary provider validation failures remain fail-closed.
- Current code now includes agent-level `fallback_models`, lifecycle fallback chaining, attempt-aware pricing via `model_used`, and accounting of failed transient attempts when trustworthy usage metadata is present.
- Remaining future work is richer provider-aware classification or observability, not the core fallback-chain contract.

What the implementation agent needs to add:

- richer provider/deployment descriptors, attempt-history observability, or broader provider-aware classification only if the architecture is extended further

## File-to-Document Mapping

### `spec/smith_spec.rb`

Purpose:

- asserts that `Smith` loads (version constant present) and the top-level `Smith::Error` class anchors the documented error hierarchy

Architecture basis:

- Section 5.6, Error Hierarchy

Documented contracts covered:

- `Smith::VERSION` and `Smith::EXECUTION_SEMANTICS_VERSION` are defined
- `Smith::Error < StandardError`

Notes:

- Trivial smoke spec; the full namespace + error taxonomy assertions live in `spec/smith/architecture_spec.rb`.

### `spec/smith/architecture_spec.rb`

Purpose:

- asserts the core namespace surface promised by the architecture
- asserts the documented error taxonomy
- asserts foundational trace and persistence namespaces from the roadmap and gem structure

Architecture basis:

- Section 4, Core Abstractions
- Section 4.8, Observability
- Section 5.6, Error Hierarchy
- Section 7, Gem Structure
- Section 11, Implementation Roadmap

Documented contracts covered:

- `Smith::Agent`
- `Smith::Workflow`
- `Smith::Events`
- `Smith::Event`
- `Smith::Tool`
- `Smith::Guardrails`
- `Smith::Context`
- `Smith::Budget`
- `Smith::Artifacts`
- `Smith::Trace`
- `Smith::Errors`
- `Smith::Types`
- `Smith::Trace::Memory`
- `Smith::Trace::Logger`
- `Smith::Trace::OpenTelemetry`
- `Smith::Workflow::Persistence`
- `Smith::BudgetExceeded`
- `Smith::DeadlineExceeded`
- `Smith::MaxTransitionsExceeded`
- `Smith::GuardrailFailed`
- `Smith::ToolGuardrailFailed`
- `Smith::ToolPolicyDenied`
- `Smith::AgentError`
- `Smith::WorkflowError`
- `Smith::SerializationError`

Notes:

- This spec intentionally checks namespace existence and inheritance hierarchy only.
- It does not prescribe implementation layout beyond the names explicitly promised in the architecture.

### `spec/smith/configuration_spec.rb`

Purpose:

- asserts the top-level configuration API used explicitly in artifacts and observability sections

Architecture basis:

- Section 4.7, Artifact Store
- Section 4.8, Observability

Documented contracts covered:

- `Smith.configure`
- yielded configuration writers:
  - `artifact_store=`
  - `artifact_retention=`
  - `artifact_encryption=`
  - `artifact_tenant_isolation=`
  - `trace_adapter=`
  - `trace_transitions=`
  - `trace_tool_calls=`
  - `trace_token_usage=`
  - `trace_cost=`
  - `trace_content=`
  - `trace_attribution=`
  - `trace_provider_calls=`
- `trace_content` defaults to `false` (content tracing is opt-in)
- structural trace fields default to enabled:
  - `trace_transitions == true`
  - `trace_tool_calls == true`
  - `trace_token_usage == true`
  - `trace_cost == true`
- `Smith.persistence_adapter` keeps a configuration with its adapter only once the adapter is built: a configuration whose adapter fails to build raises on every call, never answering the configuration's before it, and threads asking at once at first use share the one adapter built, none getting nil (Unreleased)

Notes:

- This spec checks the documented configuration surface, structural-trace defaults, and opt-in content-tracing default.
- It does not yet assert runtime adapter behavior beyond configuration values.

### `spec/smith/pricing_spec.rb`

Purpose:

- asserts the cost-computation contract for `Smith::Pricing.compute_cost(model:, input_tokens:, output_tokens:)`, including the long-context tiered-pricing shape (e.g., Gemini 2.5 Pro's 200K input cliff)

Architecture basis:

- Section 4.8, Observability (cost tracking — best-known computation, no fabrication on missing pricing)

Documented contracts covered:

- returns `nil` when no pricing config is set (`Smith.config.pricing` is nil)
- returns `nil` when the model is not in the catalog (catalog miss)
- flat shape (`{input_cost_per_token, output_cost_per_token}`): computes `input * input_rate + output * output_rate`
- flat shape: returns `nil` when rates are not Numeric (defensive — malformed catalog entry is treated as unknown rather than fabricated as 0)
- tiered shape (`{tiers: [{max_input_tokens, input_cost_per_token, output_cost_per_token}, ...]}`):
  - picks the first tier whose `max_input_tokens` covers the call's `input_tokens` (≤ inclusive; exact-at-threshold uses the lower-priced tier)
  - `nil` `max_input_tokens` is treated as the unbounded ceiling (last-tier fallthrough)
  - one-token-over-threshold falls into the next tier (verifies the boundary is correct, not off-by-one)
- both flat and tiered shapes accept either symbol or string keys (JSON round-trip safety from host-persisted pricing config)
- a Symbol catalog key reads as its text at admission: a qualified one is admitted, a model-only one refused (Unreleased)
- how a catalog key reads is not among `Smith::Pricing.constants` (Unreleased)

Notes:

- This spec covers the cost-rate lookup contract. RunResult-level cost aggregation behavior (best-known totals, missing-pricing optimism) lives in `spec/smith/workflow/run_result_spec.rb`.

### `spec/smith/models_spec.rb`

Purpose:

- pins the `Smith::Models` registry contract: provider-qualified registration with explicit collision detection, application-side `Profile` overrides, and `find_or_infer` graceful fallback to library-shipped pattern rules when no explicit profile exists

Architecture basis:

- Section 5.1, Agent Invocation (model identity + capability profile resolution)
- Decision #1 (Replace Anthropic monkey-patch with normalizer; Models holds capabilities only, not pricing)

Documented contracts covered:

- `Smith::Models.register(profile)` keys a Profile by provider and model id; re-registering the same Profile is idempotent
- `Smith::Models.register` with a different Profile for the same provider/model identity raises `Smith::Models::CollisionError`
- `Smith::Models.register` rejects a different capability Profile for the same provider/model identity; hosts must clear and rebuild model capability overrides explicitly during reload rather than silently replacing execution semantics
- `Smith::Models.find(model_id, provider:)` resolves the exact provider/model profile
- `Smith::Models.find(model_id)` returns nil for unregistered ids, resolves a sole profile, and fails closed with `AmbiguousProfileError` when multiple providers share the id
- `Smith::Models.find_or_infer(model_id, provider:)` consults only the exact provider-qualified override before inference and safe defaults
- `Smith::Models.guess_provider(model_id)` matches prefix patterns: claude → :anthropic, gpt/oN → :openai, gemini → :gemini, else → :unknown
- `Smith::Models.all` returns registered Profiles sorted by model_id
- `Smith::Models.clear!` resets the registry (test isolation)

Notes:

- Smith ships ZERO hardcoded model_ids at the registry level. Library-level capability knowledge lives in `Smith::Models::Inference` as PROVIDER-FAMILY pattern rules. Explicit `register(...)` calls are reserved for application-side overrides (custom finetunes, non-standard provider gateways).

### `spec/smith/models/inference_spec.rb`

Purpose:

- pins the pattern-based `Smith::Models::Inference` rules that describe how each PROVIDER FAMILY shapes its API payload, without coupling Smith to specific model_ids

Architecture basis:

- Section 5.1, Agent Invocation (per-provider request normalization)
- Decision #2 (Normalizer hook point + library-shipped pattern rules over per-model registrations)

Documented contracts covered:

- Anthropic Opus 4.7+ rule matches via version-aware predicate (Opus 4-N where N ≥ 7); profile is `:adaptive` thinking, accepts_temperature false, tools_with_thinking_native true
- Anthropic Opus/Sonnet/Haiku 4.0-4.6 rule matches; profile is `:budget_tokens` thinking, accepts_temperature true
- Claude 3.7 (extended thinking via budget_tokens) rule matches via prefix
- Claude 3.5 / 3.0 / 2.x fallback rule matches; no thinking, accepts_temperature true
- OpenAI gpt-5 family + o-series rule matches; profile is `:reasoning_effort` thinking, accepts_temperature false, tools_with_thinking_route `:responses`
- OpenAI gpt-4.x rule matches; no thinking, accepts_temperature true
- Gemini 2.5+ rule matches via version-aware predicate; profile is `:budget_tokens`, accepts_temperature true
- Gemini 1.x / 2.0 rule matches; no thinking
- `Inference.prepend_rule(rule)` allows hosts to inject custom matchers ahead of library defaults
- `Inference.with_rules(*overrides) { ... }` provides block-form rule substitution; restores defaults after the block (even if it raises)
- `Inference.reset!` restores default rules

Notes:

- Rule order matters: more specific patterns first. The library-shipped `default_rules` set is frozen at module load.

### `spec/smith/models/normalizer_spec.rb`

Purpose:

- pins `Smith::Models::Normalizer.apply!`'s per-attempt request-shape translation: drops temperature where the resolved Profile forbids it, translates Anthropic Opus 4.7+ adaptive thinking into the documented payload shape, routes (gpt-5 + tools + thinking) via `openai_api_mode: :responses` when supported, drops incompatible tools otherwise

Architecture basis:

- Section 5.1, Agent Invocation (provider integration)
- Decision #1 (Replace monkey-patch with normalizer at chat-construction)
- Decision #9 (Observability: normalizer emits `:normalizer_decision` trace events)

Documented contracts covered:

- Opus 4.7 profile: nulls `@temperature`, sets `@params[:thinking] = { type: "adaptive" }` + `output_config[:effort]`; nulls `@thinking` so RubyLLM doesn't ALSO emit the legacy budget_tokens shape
- Opus 4.7 profile preserves prior `with_params` calls (read-merge-write, no replacement)
- gpt-5.5 profile with `openai_api_mode = :auto`: injects `@params[:openai_api_mode] = :responses`, preserves tools (they run via /v1/responses)
- gpt-5.5 profile with `openai_api_mode = :off`: drops tools per `Tool::Compatibility` and clears a forced choice that names a dropped tool
- explicit transport provider overrides model-name inference for endpoint routing; OpenRouter chats cannot be routed through OpenAI Responses
- a transport-provider override preserves provider-agnostic model capabilities but clears endpoint assumptions inferred for another provider
- automatic OpenAI endpoint routing selects Responses only when it preserves a strictly larger compatible tool subset; ties preserve the current endpoint
- a specifically forced tool selects its compatible enabled endpoint before aggregate compatible-tool counts are compared
- `chat`, `create`, `create!`, and `find` all apply the same normalization and compatibility contract
- persisted-chat dynamic configuration receives reserved model, provider, and endpoint inputs before evaluation
- persisted `find` derives those reserved inputs from the stored chat identity rather than a later agent declaration
- Gemini 2.5+ profile preserves `@thinking` (provider renderer emits budget_tokens natively) and `@temperature`
- unknown model passes through `find_or_infer`; safe-default profile leaves `@thinking` + `@temperature` unchanged
- `Smith::Trace.record(type: :normalizer_decision, ...)` fires per mutation; gated by `Smith.config.trace_normalizer`
- forced-choice reset metadata is attributed only to the selected tool removed by compatibility filtering
- five Decision kinds: `:temperature_dropped`, `:thinking_dropped`, `:thinking_translated_to_adaptive`, `:routed_via_responses`, `:tool_dropped`

Notes:

- The normalizer is constructed fresh inside `Smith::Agent.chat` per chat construction; never crosses threads, never cached. The decision kind vocabulary is closed; adding a new kind requires updating the trace adapter `CONFIG_MAP` entries.

### `spec/smith/tool/compatibility_spec.rb`

Purpose:

- pins the `Smith::Tool::Compatibility` DSL and its consumer protocol: tool classes declare which (provider, endpoint) combinations they tolerate, and the Normalizer drops incompatible tools at chat construction

Architecture basis:

- Section 6, Tool Governance (provider-aware tool selection)
- Decision #8 (`Tool.compatible_with(...)` DSL + `Smith::Tool.inherited` dups spec)

Documented contracts covered:

- `Tool.compatible_with :anthropic, :gemini` parses an allowlist of providers; openai is excluded
- `Tool.compatible_with :anthropic, openai: :responses` allows OpenAI only on the `:responses` endpoint
- `Tool.compatible_with except: { openai: :chat_completions }` parses a denylist; openai chat-completions is excluded, other (provider, endpoint) pairs pass
- `Tool.inherited` hook dups `@compatible_with_spec` from parent so subclass tool classes inherit compatibility metadata
- `Compatibility.allows?(spec, profile)` returns true when spec is nil (no DSL declaration on the tool class means universally compatible)
- `Smith::Tools::Think` declares compatibility with `:anthropic`, `:gemini`, and `openai` on `:responses` only
- OpenAI Responses-only tools route to `:responses` even when model thinking is
  inactive; compatibility is an endpoint contract, not a thinking-only hint
- disabling Responses routing drops a Responses-only OpenAI tool before the
  provider request
- String providers in `compatible_with` read as Symbols, so they match a profile's provider (Unreleased)

Notes:

- Tool drop is budget-safe: Smith charges tool budget at `execute` time, NOT at attach time. Normalizer-dropped tools are never charged, so no orphaned budget reservation.

### `spec/smith/agent/dynamic_model_spec.rb`

Purpose:

- asserts the block-form `model` DSL extension that resolves an agent's model id at chat-construction time using the workflow's `@context`

Architecture basis:

- Section 5.1, Agent Invocation (Dynamic model selection via block-form `model`)
- Section 12, Resolved Design Decisions (Decision #34 — `model` DSL forms)

Documented contracts covered:

- static-form `model "id"` stores into `@chat_kwargs[:model]` and leaves `@model_block` nil — pre-existing behavior preserved as a regression pin
- static-form drives a registered workflow-execute transition with the declared model id (regression — confirms the new DSL surface does not affect the existing single-model path)
- block-form `model { |ctx| ... }` stores the block as `@model_block` and leaves `@chat_kwargs[:model]` nil — block storage is the source of truth, not a Proc-in-chat_kwargs
- passing both a string id and a block to `model` raises `ArgumentError` with the message `"can take a string id OR a block, not both"` — the two forms are mutually exclusive within a single declaration
- redeclaring static after block clears `@model_block` (and clears any prior `@chat_kwargs[:model]` when redeclaring block after static) — single source of truth per declaration
- block-form is evaluated at chat-construction time using the workflow's `@context` — the workflow constructor's `context: { ... }` Hash flows into the block as the sole positional argument
- the workflow's default empty context (a Hash) is supplied to the block so blocks can read keys without `NoMethodError` — `@context || {}` fallback in `resolve_dynamic_model`
- block-form composes with `fallback_models` — `build_model_chain` returns `[resolved_block_result, *fallback_models]` in declared order, same path as the static-form `[chat_kwargs[:model], *fallback_models]`
- block returning `nil` raises `Smith::AgentError` with the message `"must return a non-empty string"` — surfaces as a step failure through the workflow's `on_failure` transition rather than a silent miss
- block returning empty string raises `Smith::AgentError`
- block returning non-string (e.g., Symbol) raises `Smith::AgentError`
- subclasses inherit the parent's `@model_block` — added to `Smith::Agent.inherited` alongside the existing `@budget_config`, `@guardrails_class`, `@output_schema_class`, `@data_volume`, `@fallback_models_list` copies
- subclasses can redeclare with a static model, clearing the inherited block — preserves the override semantics of the existing class-level DSLs

Notes:

- The block-form is **workflow-execution-path scoped**. Direct `agent_class.chat()`, `create()`, `create!()` calls outside Smith's workflow lifecycle do NOT currently resolve the block — they pass `chat_kwargs[:model]` (which is nil for block-form agents) directly to RubyLLM. AR-backed agents (those using `chat_model SomeModel` for chat-record persistence) should use static-form `model "id"` until block resolution is extended through `with_rails_chat_record`. This limitation is reflected in the resolution path: `Smith::Agent::Lifecycle#resolve_dynamic_model` is invoked from `build_model_chain`, which is only reached via `complete_with_provider` from workflow execution.
- The block receives the workflow's `@context` (a Hash). This is the same `@context` available to `run_after_completion`, NOT the `runtime_context` passed to `instructions do |ctx|` blocks (which is RubyLLM's runtime context — a richer object with `.chat` / `.inputs` accessors). The two context shapes are intentionally different: model resolution is a workflow-level concern (driven by workflow seed_messages / context_manager), instructions are an agent-level concern (driven by RubyLLM's input partitioning).
- Parallel branches resolving block-form models all share the workflow's `@context` (Smith does not clone context per branch). Since the block is class-level and stateless, all branches resolve to the same model id consistently. Hosts that mutate `@context` mid-execution would observe non-deterministic resolution; Smith does not protect against this.
- Resolution happens per-attempt within the fallback chain, but the block is invoked only once for the chain (not once per attempted fallback) — fallbacks themselves remain static via `fallback_models`. This matches the architectural decision that fallback is a transient-failure-recovery mechanism, not a per-call routing primitive.
- Coverage gaps deferred (no specs in this file): block raising an exception during evaluation (propagates as Smith::AgentError via the rescue in `complete_with_provider`); block returning a non-Symbol non-String non-nil value (Hash / Integer / Array — same `is_a?(String)` check rejects all); deeply nested inheritance (subclass-of-subclass-of-subclass — single-level coverage assumed sufficient given the inheritance hook is straightforward `instance_variable_set`).

### `spec/smith/agent/inputs_bridge_spec.rb`

Purpose:

- asserts the workflow-input bridge that Smith's lifecycle uses to flow declared agent `inputs` from the workflow's `@context` Hash to the agent invocation, enabling RubyLLM block-form DSLs (tools, instructions, params, headers, schema) to evaluate against workflow-context data via `runtime_context.<input_name>`

Architecture basis:

- Section 5.1, Agent Invocation (Workflow-input bridge for declared `inputs`)
- Section 12, Resolved Design Decisions (Decision #35 — workflow-input bridge)

Documented contracts covered:

- declared inputs from `@context` flow to `agent_class.chat` kwargs at `Smith::Agent::Lifecycle#attempt_model` time — the workflow `@context[:form_kind]` arrives as `chat(form_kind: "article")`, and RubyLLM's input partitioning then surfaces it on `runtime_context.form_kind` for block-form RubyLLM DSLs
- the bridge is a no-op for agents without declared `inputs` — only `model:` is passed to chat, so static-form agents see no behavioral change
- inputs declared but absent from `@context` are skipped — they are not passed as `nil` (cleaner runtime_context shape; absent input means absent attribute, not present-but-nil)

Notes:

- The bridge complements block-form `model` (which receives `@context` directly as a Hash via `Smith::Agent::Lifecycle#resolve_dynamic_model`). `model` is a workflow-level concern (resolved before chat construction); the RubyLLM blocks are agent-level concerns (resolved during chat configuration). The bridge is the seam — it keeps both context shapes intentional: `@context` Hash for `model`, runtime_context object for everything else.
- Non-Hash `@context` short-circuits the bridge to an empty-kwargs result (host context_managers that emit non-Hash structures still work without breaking the bridge).
- The bridge respects RubyLLM's existing input contract: `agent_class.inputs` is the declared list (RubyLLM's `inputs(*names)` setter / getter); the bridge only iterates that list, never additional `@context` keys. This prevents accidentally leaking workflow-internal context (budget, persistence keys, intermediate compute outputs) into the chat kwargs.
- The same spec covers the RESERVED_INPUT_NAMES merge + collision contract: `Smith::Agent.inputs` no-arg getter returns reserved ∪ user (frozen, deduplicated); setter validates user names against `RESERVED_INPUT_NAMES` and raises `Smith::AgentError` on collision; the bridge slices to USER-DECLARED inputs only so stale `@context[:model_id]` / `[:provider]` / `[:endpoint_mode]` values cannot override the profile-resolved values that `Smith::Agent.chat` injects from `Smith::Models::Profile`.

### `spec/smith/agent/cross_provider_fallback_spec.rb`

Purpose:

- pins the cross-provider fallback contract: when primary Claude fails with a transient error, fallback gpt-5.5 runs with a fresh, model-aware chat config because `Smith::Models::Normalizer` fires per attempt

Architecture basis:

- Section 5.1, Agent Invocation (fallback chain)
- Section 9, Fallback Model Chains
- Decision #1 (Normalizer at `Smith::Agent.chat`; covers workflow + direct paths)

Documented contracts covered:

- Opus 4.7 primary attempt: adaptive thinking translation, temperature nulled
- gpt-5.5 fallback attempt: `@thinking` preserved (provider renderer emits `reasoning_effort` natively), `@temperature` nulled
- reserved runtime inputs (`:model_id`, `:provider`, `:endpoint_mode`) injected per attempt from the resolved Profile
- Anthropic path retains Think tool (native tools + thinking)
- gpt-5.5 path with `openai_api_mode = :off` drops Think tool (graceful degradation per `Tool::Compatibility`)
- gpt-5.5 path with `openai_api_mode = :auto` sets `@params[:openai_api_mode] = :responses` for routing

Notes:

- Pre-refactor, this scenario was broken: same chat config went to both providers; gpt-5 + tools + reasoning_effort failed with non-transient `BadRequestError`; fallback chain never recovered. This spec pins the fix.

### `spec/smith/agent/direct_chat_normalization_spec.rb`

Purpose:

- pins the direct-call normalization contract: `Smith::Agent.chat()` fires the Normalizer outside the workflow lifecycle, covering hosts that call agent chat directly

Architecture basis:

- Section 5.1, Agent Invocation (provider integration outside workflow execution)
- Decision #2 (Normalizer at `Smith::Agent.chat()` not `Lifecycle#attempt_model`)

Documented contracts covered:

- Opus 4.7 direct chat: adaptive thinking translation, temperature nulled
- adaptive translation persists after `add_message` (no undo from downstream chat operations)
- explicit `model:` kwarg overrides class-level `chat_kwargs[:model]`
- Gemini 2.5+ direct chat preserves `@thinking` + `@temperature` (budget_tokens shape)
- agent with no `model` declared and no `model:` kwarg skips normalization (profile is nil)
- `:normalizer_decision` trace events fire from direct chat construction

Notes:

- This is the reason Smith hooks the normalizer at `Smith::Agent.chat()` rather than at `Lifecycle#attempt_model`. The workflow-only hook point would miss every direct caller.

### `spec/smith/agent/contract_spec.rb`

Purpose:

- asserts the central `Smith::Agent` layering contract
- verifies that Smith extends RubyLLM rather than replacing it
- verifies the extra DSL surface promised by the architecture

Architecture basis:

- Section 4.1, Agent
- Section 5.1, Agent Invocation
- Section 11, Phase 1 Foundation

Documented contracts covered:

- `Smith::Agent < RubyLLM::Agent`
- RubyLLM compatibility surface retained:
  - `.chat_model`
  - `.model`
  - `.tools`
  - `.instructions`
  - `.temperature`
  - `.thinking`
  - `.schema`
  - `.find`
  - `.create`
  - `.chat`
- Smith DSL additions:
  - `.budget`
  - `.guardrails`
  - `.output_schema`
  - `.data_volume`
  - `.register_as`

Notes:

- The spec uses a stub class to confirm the documented DSL shape can be declared.
- It does not assert invocation behavior yet. That belongs in future runtime specs once the implementation exists.

### `spec/smith/agent/registry_spec.rb`

Purpose:

- asserts the explicit agent-to-workflow registry seam described in workflow execution

Architecture basis:

- Section 5.2, Workflow Execution
- Section 7, Gem Structure

Documented contracts covered:

- `Smith::Agent::Registry`
- `.find` — resolves registered agents by name
- `.fetch!` — resolves or raises `WorkflowError` with context
- `.delete` — per-key deletion with key normalization
- `.clear!` — full registry reset for test isolation
- `.ensure_registered` — reload-safe registration:
  - missing → register
  - same object → no-op
  - same `.name` (stale reload) → atomic replace
  - different `.name` → raise `AgentRegistryError`
  - validates input is a `Smith::Agent` subclass
- `.register` (overridden) — routes agent classes through `ensure_registered`, preserves generic `Dry::Container` semantics (block, options) for non-agent values
- `.register_as` — reload-safe (delegates to `ensure_registered`); `publish: false`
  records the registration identity without exposing the class, allowing a host
  to seal generated configuration before publishing it through
  `.publish_registration!`; staged string identities are copied and frozen,
  and publication cannot substitute a different registry key
- `registry_monitor` — re-entrant `Monitor` synchronizes all operations (reads and writes share the same lock; safe for block-backed entries that re-enter the registry)
- collision semantics — agent-vs-agent different name, agent-vs-non-agent, anonymous class collisions all raise `AgentRegistryError`

Notes:

- This spec does not yet assert inferred registration from class name because the document frames that as a convention, not a mandatory Phase 1 contract.

### `spec/smith/agent/fallback_spec.rb`

Purpose:

- asserts the first-phase agent-level fallback model-chain runtime behavior

Architecture basis:

- Section 5.1, Agent Invocation (Fallback model chains)
- Section 11, Phase 4 Production Readiness

Documented contracts covered:

- primary model success does not invoke fallbacks
- transient upstream failure falls through to the next ordered fallback model
- exhausted fallback chain fails with `Smith::AgentError`
- non-transient provider errors do not fallback
- `Smith::Error` subclasses do not fallback
- fallback model chains are inherited by subclasses
- agents without `fallback_models` retain single-model behavior
- fallback model lists deduplicate entries while preserving order
- provider-qualified fallback entries retain their exact transport provider, while unqualified string entries fail closed during agent configuration
- successful fallback attempts are priced against the model that actually succeeded
- failed transient attempts with known usage contribute to aggregate token and best-known cost accounting
- failed transient attempts with unknown usage remain optimistic and do not fabricate accounting
- blank fallback model entries are rejected

Notes:

- Fallback remains an agent-lifecycle helper, not a workflow-level routing primitive.
- Transition-level retry is covered by `spec/smith/workflow/retry_policy_spec.rb`.
  Agent fallback remains a separate model-chain concern.
- This spec covers the bounded local fallback chain, not richer provider/deployment-specific failover policy.

### `spec/smith/workflow/retry_policy_spec.rb`

Purpose:

- asserts bounded transition-level retry behavior

Architecture basis:

- Section 5.2, Workflow Execution
- Section 11, Phase 4 Production Readiness

Documented contracts covered:

- `retry_on attempts:` retries errors classified by `Smith::Errors.retryable?`
  when no explicit error classes are supplied
- explicit retry classes opt a transition into retrying those error families
- retry attempts are bounded and exhaustion routes through normal failure
  handling
- non-retryable errors fail without extra attempts
- declaration-time validation rejects invalid attempts, error classes, and delay
  controls
- graph inspection exposes retry policy metadata without executing the workflow

### `spec/smith/workflow/contract_spec.rb`

Purpose:

- asserts the core workflow DSL and execution entry points
- asserts the documented transition declaration shape

Architecture basis:

- Section 4.2, Workflow
- Section 5.2, Workflow Execution
- Section 5.4, Guardrail Attachment

Documented contracts covered:

- class DSL:
  - `.initial_state`
  - `.state`
  - `.transition`
  - `.budget`
  - `.max_transitions`
  - `.guardrails`
  - `.context_manager`
  - `.seed_messages`
  - `.persistence_key`
  - `.graph`
  - `.validate_graph`
- instance/class execution surface:
  - `#advance!`
  - `#run!`
  - `#terminal?`
  - `#done?`
  - `#failed?`
  - `#advance_persisted!`
  - `#persist!`
  - `#clear_persisted!`
  - `#run_persisted!`
  - `#state`
  - `#to_state`
  - `.restore`
- `.restore_or_initialize`
- `.run_persisted!`
- `.from_state`
- execute transitions fail loudly when a declared agent symbol is not registered
- transition block surface:
  - `execute`
  - `on_success`
  - `on_failure`
- declared transitions retain:
  - `from`
  - `to`
  - `agent_name`
  - `agent_opts`
  - `success_transition`
  - `failure_transition`
- default `:fail` transition is auto-generated when a workflow declares `:failed`
- explicit `:fail` transition overrides the auto-generated default

Notes:

- This spec checks DSL surface and declared transition metadata only.
- The default `:fail` transition contract is covered here even if the current implementation is still failing that spec.
- The architecture gives enough support for the DSL shape, but not yet enough detail to assert all transition side effects without over-prescribing implementation.

### `spec/smith/workflow/graph_spec.rb`

Purpose:

- asserts the static workflow graph inspection surface
- asserts pre-runtime diagnostics for declared workflow topology

Architecture basis:

- Section 2, Control Flow Shape
- Section 4.2, Workflow
- Section 5.2, Workflow Execution
- Named transition validation contract

Documented contracts covered:

- `.graph` returns a read-only inspection object for the workflow class
- `.validate_graph` returns a report without executing agents or advancing workflow state
- declared state and transition names are preserved without graph-level coercion
- report surface:
  - `#valid?`
  - `#status`
  - `#errors`
  - `#warnings`
  - `#suggestions`
  - `#to_h`
- transition snapshots expose:
  - `name`
  - `from`
  - `to`
  - `kind`
  - `success_transition`
  - `failure_transition`
  - router `routes`
  - router `fallback`
  - fan-out branch map
  - fan-out join metadata (`branch_count`, `join_state`, ordered branch list, and output shape)
  - optimizer contracts (generator/evaluator bindings, max rounds, schema label, evaluator context, exit modes, output contract, and transition-level resume contract)
  - optimizer output contracts distinguish required `accept`, rejection-required
    `feedback`, threshold-required `score`, and optional `score` / `converged`
  - orchestrator-worker contracts (orchestrator/worker bindings, bounds, schema labels, decision/output contracts, dispatch semantics, and transition-level resume contract)
- diagnostics cover:
  - missing or undeclared initial state
  - undefined `from` and `to` states
  - unresolved `on_success` and `on_failure` targets
  - unresolved router route/fallback targets
  - error-level target state mismatches that would fail at runtime
  - warning-only unreachable transitions
- metrics cover:
  - state count
  - transition count
  - reachable transition count
  - terminal states
- `.runtime_readiness` returns a static report that separates topology status
  from runtime binding readiness
- runtime readiness report surface:
  - `#ready?`
  - `#valid?`
  - `#status`
  - `#topology_status`
  - `#diagnostics`
  - `#runtime_diagnostics`
  - `#errors`
  - `#warnings`
  - `#suggestions`
  - `#metrics`
  - `#to_h`
- runtime readiness diagnostics cover:
  - unregistered agent bindings across execute, route, optimize, orchestrate,
    and fan-out transitions
  - invalid non-agent registry bindings as errors
  - lazy/uninspectable registry bindings without resolving the lazy binding
  - registered agent bindings without configured models as warnings when the
    role can run without model output
  - model-required roles as errors when the registered agent has no configured
    model
  - nested workflow readiness diagnostics projected onto the parent transition
- runtime readiness metrics cover:
  - topology status
  - direct and transitive agent binding counts
  - unresolved agent binding count
  - invalid agent binding count
  - uninspectable agent binding count
  - model-less agent binding count
  - required-model missing count
  - direct and transitive nested workflow counts
  - direct and transitive fan-out group and branch counts

Notes:

- Graph inspection is static and diagnostic-only.
- Runtime readiness is also static and diagnostic-only.
- This spec intentionally does not introduce host-owned progress projection,
  durable retry scheduling, provider calls, tool execution, or recovery
  semantics into Smith core. Static retry-policy bounds remain part of runtime
  readiness diagnostics.
- Runtime loud-failure behavior for unresolved named transitions remains covered in deterministic-step and run-result specs.

### `spec/smith/workflow/durability_spec.rb`

Purpose:

- asserts the small configured-adapter durability convenience surface for workflows

Architecture basis:

- Section 4.2, Workflow
- Section 5.3, State Serialization

Documented contracts covered:

- `.restore(key, adapter:)` restores a workflow from configured host persistence, requires a non-blank explicit key, and treats the lookup key as authoritative over any embedded persisted key
- `.restore_or_initialize(key:, context:, adapter:)` returns restored state when present or a new workflow when absent, and can derive the key from workflow-declared `persistence_key`
- `.restore_or_initialize` and `.run_persisted!` pass their other keywords (such as `created_at:`) on to `new` (Unreleased)
- `.run_persisted!(key:, context:, adapter:, clear:, on_step:)` restores or initializes, checkpoints through terminal state, supports synchronous per-run step callbacks, and can clear terminal state through a configurable policy
- `#advance_persisted!(key, adapter:, on_step:)` checkpoints around a single accepted transition for stepwise resume loops
- `#run_persisted!(key, adapter:, on_step:)` checkpoints before execution and after each accepted step
- `#persist!(key, adapter:)` writes serialized workflow state through the configured adapter and can derive the key from workflow context
- `#clear_persisted!(key, adapter:)` clears serialized workflow state through the configured adapter and can derive the key from workflow context
- derived persistence keys remain stable across restore for instance-level helpers, even when workflow context persistence is filtered
- durability helpers fail with `Smith::WorkflowError` when no persistence adapter is available
- durability helpers fail with `Smith::WorkflowError` when no explicit key is passed and no workflow `persistence_key` is available
- durability helpers fail with `Smith::WorkflowError` when workflow `persistence_key` resolves to nil or blank
- `on_step:` callback failures are logged and do not abort durable workflow progression
- `clear: :terminal` clears any terminal workflow state, not only `:done`/`:failed`
- `#run_persisted!` and `#advance_persisted!` avoid no-op persistence writes when the workflow is already terminal
- workflow predicates:
  - `#terminal?`
  - `#done?`
  - `#failed?`
- run-result predicates/helpers:
  - `#done?`
  - `#failed?`
  - `#terminal_output`
  - `#last_error`

Notes:

- These helpers are convenience wrappers around the configured persistence adapter, not a durable orchestration runtime.
- Host apps still own persistence backend selection, workflow keys, queue delivery, and terminal domain projection.

### `spec/smith/workflow/seed_messages_spec.rb`

Purpose:

- asserts the workflow-level seed-message DSL for deterministic initial session history

Architecture basis:

- Section 4.2, Workflow
- Section 4.6, Context Manager

Documented contracts covered:

- `.seed_messages` stores a workflow-local callable used to initialize session history for new workflows
- seeded messages appear in persisted `session_messages` for newly initialized workflows
- seeded session messages are passed into normal agent execution
- seeded messages do not rerun or duplicate on restore

Notes:

- `seed_messages` is a workflow convenience for deterministic starting turns.
- It complements `Smith::Context`; it does not replace context persistence or injected state.
- `persistence_key` is a workflow convenience for deterministic durability addressing.
- It complements host-owned key selection; it does not introduce workflow-server conflict semantics.

### `spec/smith/workflow/patterns_spec.rb`

Purpose:

- asserts the explicit pattern namespaces promised in the roadmap
- asserts that orchestrator-worker remains bounded by workflow limits, not free-form loops

Architecture basis:

- Section 3, Design Principles
- Section 5.2, Workflow Execution
- Section 11, Phase 3 Workflow Patterns

Documented contracts covered:

- `Smith::Workflow::Pipeline`
- `Smith::Workflow::Router`
- `Smith::Workflow::Parallel`
- workflow transition-bounded execution via `.max_transitions`

Notes:

- This spec covers presence of the named pattern entry points only.
- Pipeline runtime behavior is covered in `spec/smith/workflow/pipeline_spec.rb`.
- Router runtime behavior is covered in `spec/smith/workflow/router_spec.rb`.
- Evaluator-optimizer runtime behavior is covered in `spec/smith/workflow/evaluator_optimizer_spec.rb`.
- Orchestrator-worker runtime behavior is covered in `spec/smith/workflow/orchestrator_worker_spec.rb` and, over a provider's String-keyed replies, `spec/smith/workflow/orchestrator_worker_keys_spec.rb`.

### `spec/smith/workflow/pipeline_spec.rb`

Purpose:

- asserts the Pipeline declarative linear-stage runtime behavior

Architecture basis:

- Section 5.2, Workflow Execution (Pipeline helper)

Documented contracts covered:

- pipeline stages execute in declared order
- each stage compiles to ordinary workflow transitions with generated `on_success` chaining
- the last stage output surfaces as the workflow result
- pipeline stage failure routes through normal `on_failure`
- a pipeline must declare at least one stage
- pipeline name is required
- pipeline `from:` is required
- pipeline `to:` is required
- stage name is required
- stage `execute:` is required
- stage names must be unique within a pipeline
- generated transition names must not collide with existing workflow transitions

Notes:

- Pipeline is a DSL/compiler layer only; it does not introduce a separate runner.
- Existing workflow runtime behavior still applies unchanged once the generated transitions execute.

### `spec/smith/workflow/router_spec.rb`

Purpose:

- asserts the Router structured intent classification runtime behavior

Architecture basis:

- Section 5.2, Workflow Execution (Router helper)

Documented contracts covered:

- high-confidence classifier result selects the mapped specialist transition
- low-confidence result selects the configured fallback transition
- unknown route key in classifier output fails the step normally
- mapped transition name must be declared on the workflow or the step fails normally
- fallback transition name must be declared on the workflow or the step fails normally
- missing `:route` key in classifier output fails the step normally
- missing `:confidence` key in classifier output fails the step normally
- confidence outside 0.0..1.0 fails the step normally
- non-hash classifier output fails the step normally
- classifier agent failure routes through on_failure
- router steps fail loudly when the declared classifier agent symbol is not registered
- router classifier output still passes through normal output guardrails before routing is finalized
- transitions remain the control-flow authority across a full routed workflow

Notes:

- Router selects transition names, not agents directly. Transitions remain authoritative.
- Classifier agent uses the normal agent invocation path (budget, deadline, AgentError wrapping, token_usage trace all apply).
- Fallback is only for low confidence. Malformed output fails the step, never silently falls back.

### `spec/smith/workflow/evaluator_optimizer_spec.rb`

Purpose:

- asserts the Evaluator-optimizer bounded generator/evaluator refinement runtime behavior

Architecture basis:

- Section 5.2, Workflow Execution (Evaluator-optimizer helper)
- Section 11, Phase 3 Workflow Patterns

Documented contracts covered:

- accepted candidate returns as the step output
- bounded exhaustion at `max_rounds` fails the step normally
- `converged: true` without acceptance fails the step normally
- improvement below the configured `improvement_threshold` fails the step normally
- evaluator output missing `:accept` fails the step normally
- non-boolean evaluator `:accept` fails the step normally
- rejected evaluator output must include `:feedback`
- optimize declaration requires `generator`
- optimize declaration requires `evaluator`
- optimize declaration requires `evaluator_schema`
- optimize declaration requires positive integer `max_rounds`
- optimizer steps fail loudly when the configured generator or evaluator symbol is not registered
- transition DSL rejects combining `optimize` with `execute`
- generator and evaluator rounds participate in normal serial budget reservation and reconciliation
- optimization rounds remain inside one parent workflow step
- the single stable instruction layer remains `system`
- refinement-round metadata and evaluator feedback remain turn-local `user` content, while the prior candidate is passed as `assistant`
- every valid round's verdict is an output: the step's record carries `:evaluations` (`attempt`, `round`, `source` of `:evaluator` or `:before_eval`, and the normalized `verdict` with every schema field) whether the step completed or failed, and `RunResult#evaluations` names each record's transition
- the verdict that ends the loop is kept (exhaustion, convergence), a callable exit mode reads the verdicts so far from `state.evaluations`, a frozen copy it cannot use to rewrite the step's, and non-optimize steps, like a step that failed before its loop, carry no `:evaluations`
- in `run!` and `run_persisted!` each verdict is a frozen copy, apart from what the evaluator returned, and so is each record `RunResult#evaluations` lists; a split step's execution snapshot is the host's own mutable copy
- a verdict holding a value that is not JSON (an object, a non-finite Float, a key that is not a String or Symbol) fails the step with `Smith::WorkflowError` at its round, in `run!` and in a split step
- a round whose verdict takes the step's verdicts past a step record's limits fails the step at that round in `run!` and in a split step alike, keeping the verdicts before it
- a split step whose completion fails after its loop (its snapshot over the byte limit) keeps its verdicts on the failure record
- a step `retry_on` runs again keeps every attempt's verdicts, each naming the retry policy's attempt that ran its loop, rounds counting from 0 in each, an attempt that failed before its loop leaving a gap
- verdicts reach the host through a strict persisted run and a split step's execution snapshot

Notes:

- First-phase success requires an accepted candidate; convergence without acceptance is a bounded failure, not a best-effort success mode.
- Evaluator-optimizer remains a transition-body helper inside one workflow step; it does not introduce a second workflow runner or per-round persisted resume surface.
- This is the only native repair/refinement-style loop contract beyond local `retry_on`.
  Deterministic repair, polling/wait, and guarded state re-entry are not covered
  by this helper unless their contracts map exactly to this structured
  generator/evaluator model.

### `spec/smith/workflow/nested_execution_spec.rb`

Purpose:

- asserts the first-phase nested-workflow child-execution behavior

Architecture basis:

- Section 5.2, Workflow Execution (Nested workflow helper)
- Section 5.3, State Serialization
- Section 11, Phase 3 Workflow Patterns

Documented contracts covered:

- parent transition can bind to a child workflow class
- child workflow success returns child final output as parent step output
- child workflow failure routes parent through normal `on_failure`
- a child that raises passes its error to the parent step unchanged (any class, at any nesting depth), after its usage is rolled into the parent on every attempt: a class-less `retry_on` retries it when the child's error is retryable, a class `retry_on` matches the child's class, and a non-Smith error passes through as itself; a child that routes its failure through its own `on_failure` gives the parent a non-retryable `WorkflowError` and is never retried; when a tool ran in any child step, the parent step's failure is `Smith::ToolOutcomeUncertain`, never retried, whether the child raised or routed, and the resulting failure record restores and runs again; no retry starts once the parent's wall-clock deadline has passed (all mutation-verified against the full suite)
- workflow binding rejects non-class targets
- workflow binding rejects non-`Smith::Workflow` classes
- transition DSL rejects combining `workflow` with `execute`
- transition DSL rejects combining `workflow` with `route`
- nested execution keeps parent step count parent-scoped
- nested execution shares the parent budget ledger with the child
- nested execution inherits the parent wall-clock deadline
- nested execution inherits the parent artifact scope without nested re-wrapping
- nested child best-known cost and token totals roll into the parent workflow run result totals
- nested child rollup runs BEFORE the failed-step check raises — a child that performed billable agent work and then failed still rolls its `total_cost`, `total_tokens`, AND `usage_entries` up to the parent (closes the silent-loss-of-failed-child-billing window)
- rolled-up `usage_entries` are deep-copied via `UsageEntry.from_h(snapshot_value(entry.to_h))` so child and parent entry instances are fully independent (`Struct#dup` would alias mutable string fields like `usage_id` / `model`)
- both `:completed_attempt` and `:failed_attempt` entries from the child preserve their attempt_kind through rollup

Notes:

- This covers the first local child-execution backend, not the future durable child-execution store/backend.
- Parent-facing semantics remain simple even though the runtime uses a dedicated nested-execution seam.

### `spec/smith/workflow/orchestrator_worker_spec.rb`

Purpose:

- asserts the first-phase orchestrator-worker bounded delegation runtime behavior

Architecture basis:

- Section 5.2, Workflow Execution (Orchestrator-worker helper)
- Section 11, Phase 3 Workflow Patterns

Documented contracts covered:

- orchestrator may emit valid final output and complete the parent step successfully
- orchestrator may emit worker tasks, receive normalized worker results, and continue to a later orchestration round
- exhausting `max_delegation_rounds` without final output fails the step normally
- exceeding `max_workers` fails the step normally
- explicit `stop` signal fails the step normally
- orchestrator output must contain exactly one of `:tasks`, `:final`, or `:stop`
- non-hash orchestrator output fails the step normally
- task payloads are validated against `task_schema`
- worker outputs are validated against `worker_output_schema`
- final output is validated against `final_output_schema`
- worker failures route through normal `on_failure`
- orchestrator steps fail loudly when the configured orchestrator or worker symbol is not registered
- worker execution uses a Smith-owned worker execution seam while remaining inside one parent workflow step
- orchestrator-worker keeps parent step count parent-scoped
- the single stable instruction layer remains `system`
- orchestration-round metadata and worker results remain turn-local `user` content instead of introducing extra system messages
- orchestrate declaration requires:
  - `orchestrator`
  - `worker`
  - `task_schema`
  - `worker_output_schema`
  - `final_output_schema`
  - positive integer `max_workers`
  - positive integer `max_delegation_rounds`
- orchestrate schemas must expose the declared first-phase schema surface via `required_keys`
- transition DSL rejects combining `orchestrate` with:
  - `execute`
  - `route`
  - `workflow`
  - `optimize`

Notes:

- This covers the first local orchestrator-worker backend, not the future durable/distributed worker execution backend.
- Workers remain bounded by Smith-owned limits and inherited parent protections; the helper does not create a free-form multi-agent swarm.

### `spec/smith/workflow/orchestrator_worker_keys_spec.rb`

Purpose:

- asserts that an orchestrate step reads String-keyed structured replies, and decisions that give their unused keys as null

Architecture basis:

- Section 5.2, Workflow Execution (Orchestrator-worker helper)

Documented contracts covered:

- over the local provider server, String-keyed `tasks`, `final` and `stop` decisions run, end and stop as Symbol-keyed ones do
- a decision that gives its unused keys as null (OpenAI's strict route, a `RubyLLM::Schema` decision) is read by the one key that holds a value
- a decision in which none or two of `tasks`, `final` and `stop` hold a value, in either spelling, still fails with the same error
- tasks, worker outputs and final outputs are checked against `required_keys` in either spelling, a key holding null counting as given, as on 0.16.0; a task or final output that is not a Hash still fails; the final output is kept as the orchestrator gave it
- `Smith::Testing` stubs, whose Hash outputs reach the step as JSON, drive an orchestrate step
- a persisted run cut after its first round's worker reply restores, replays those kept String-keyed calls from the response memo, and finishes

### `spec/smith/workflow/orchestrator_worker_restore_spec.rb`

Purpose:

- asserts that a persisted orchestrate run restored after its process died asks its orchestrator what it asked before, so every call the response memo kept replays

Architecture basis:

- Section 5, Persistence and Resume; Section 5.2, Workflow Execution (Orchestrator-worker helper)

Documented contracts covered:

- a three-round run cut once the memo has kept any of its seven calls (each round's decision, each worker's reply, the final) restores and finishes with exactly the requests, holds, settlements and usage entries of an uncut run, the same output and saved context, and every kept call found in the memo
- a worker's `execution_id` in the round message is a UUID named by its run, step, round, task content and copy: no two workers of a run share one (a task repeated in a later round, or twice in one round, included), and two runs never do; under a known namespace it is the version 8 UUID its definition gives, computed in the spec with Digest and JSON alone
- it gives away no idempotency key host code gets where the worker runs
- it is the same in a restored run, whatever order its orchestrator lists the tasks in, and in another process, which replays every call the first one kept

### `spec/smith/workflow/serialization_spec.rb`

Purpose:

- asserts the persistence seam between Smith and the host app

Architecture basis:

- Section 1, Execution Model
- Section 4.2, Workflow
- Section 5.3, State Serialization
- Section 7, Gem Structure

Documented contracts covered:

- `Smith::Workflow::Persistence`
- `#to_state`
- `.from_state`

Notes:

- This spec intentionally stops at entry points.
- Exact state-shape coverage lives in `spec/smith/workflow/state_shape_spec.rb`.

### `spec/smith/workflow/state_shape_spec.rb`

Purpose:

- asserts the documented `to_state` hash shape and round-trip serialization surface

Architecture basis:

- Section 5.3, State Serialization
- Section 5.5, Assumptions

Documented contracts covered:

- exact `to_state` keys:
  - `class`
  - `state`
  - `persistence_key`
  - `context`
  - `budget_consumed`
  - `step_count`
  - `awaiting` (the run's wait, or nil)
  - `active_seconds` (time the run's steps have spent running, which a workflow `wall_clock` bounds)
  - `execution_namespace`
  - `created_at`
  - `updated_at`
  - `next_transition_name`
  - `session_messages`
  - `total_cost`
  - `total_tokens`
  - `tool_results`
  - `outcome`
  - `usage_entries` (array of `Workflow::UsageEntry` per-call billing facts; `to_h`-serialized for JSON safety)
  - `last_output` (last non-nil step output; terminal-restore fallback for `RunResult#output` when restored steps are empty)
  - `last_failed_step` (class-aware error snapshot; transition + from + to + error_class + error_family + error_message + error_retryable + error_kind + error_details — used for `RunResult#last_error` / `#failure_detail` synthesis on terminal-restore)
  - `seed_message_count` (validated immutable seed-prefix boundary used by seed-preserving observation masking)
- round-trip via `.from_state`
- resolved durability key round-trips through `.from_state`
- `budget_consumed` is serialized from the live ledger after execution
- `.from_state` rebuilds a live ledger with the same consumed and remaining budget
- resumed workflows continue reserving and reconciling budget from restored ledger state
- persisted `next_transition_name` preserves the selected resume path across restore
- invalid persisted seed-prefix lengths fail closed; legacy state defaults the boundary to zero
- a restored run's step gets what is left of its `wall_clock` after its persisted `active_seconds`; the time since `created_at` does not count, and a run that has spent its budget fails its next step with `Smith::DeadlineExceeded`
- persisted `total_cost` and `total_tokens` preserve cumulative best-known workflow totals across restore
- optional `definition_digest` binds persisted state to a host-supplied executable workflow definition
- JSON-serializable state payload
- host-style JSON round-trip restore via `JSON.generate` / `JSON.parse` preserves executable state, selected next transition, persisted context, session history, restored budget state, and persisted cumulative totals

Notes:

- This spec now covers state shape, Ruby-hash round-trip behavior, host-style JSON round-trip behavior, and restored budget-ledger equivalence.
- It does not yet assert non-serialization of every possible Ruby object in nested structures.

### `spec/smith/workflow/split_step_persistence_spec.rb`

Purpose:

- pins the generic host-transactional boundary for one strict persisted step

Documented contracts covered:

- preparation persists `step_in_progress` and returns the pending transition
  without consuming it
- legacy execution requires a prepared strict workflow and re-verifies durable
  preparation; restart-safe execution additionally requires a confirmed exact
  dispatch claim before advancing exactly one transition
- prepared execution state is detached from external mutable aliases and must
  still match the exact prepared payload before execution
- serialized state exposed after preparation is detached, so mutating it after
  durable verification cannot change the state consumed by the transition
- mutable session-state readers return defensive snapshots while a split-step
  boundary is active
- `to_state` returns a defensive snapshot while a boundary is active, and
  caller-owned timestamp and metadata strings are detached before preparation
- subclass serializers are wrapped in the same defensive snapshot boundary
- post-preparation workflow class mutation is outside the supported lifecycle;
  custom `inherited` hooks must preserve `super`
- the in-memory marker remains armed until committed checkpoint completion, so
  pre-completion serialization fails closed
- split-step execution rejects non-versioned adapters, adapters whose
  `store_versioned` method cannot accept explicit `ttl:`, and expiring
  persistence
- preparation refuses a step declared `from: nil`, a fan-out one included,
  with a `Smith::WorkflowError` naming the step and saying to run it with
  `advance_persisted!`, before anything is written; the run then goes on that way
- restart-safe split steps additionally require exact-payload `replace_exact`
  and a bounded stable `persistence_identity`
- exact dispatch claiming is a public work-free phase, retains the logical
  workflow version, and permits only one original or recovered process to enter
  transition work
- execution authorization is a separate work-free phase that verifies the
  exact durable preparation or dispatch before a host commits its own attempt
  boundary
- execution capabilities are process-local, non-copyable, reject standard Ruby
  serialization hooks, and use exact identity; release and consumption
  linearize so only one wins
- forked children cannot consume process-bound authority, and exact direct or
  composite agent bindings are captured before host work begins
- consuming an authorization revalidates the sealed definition and exact
  transition contract immediately before work
- typed execution results preserve successful and failure-routed attempts
  independently of the workflow's resulting state
- transactional dispatch claims remain non-executable until commit
  confirmation; exact rollback restores the prepared boundary while any other
  confirmation result fails closed
- ambiguous exact-claim acknowledgement remains durable `dispatching` state
  and cannot be recovered as `not_started`
- non-expiring persistence is pinned across preparation and checkpoint even if
  global persistence TTL configuration changes mid-boundary
- subclass execution entry points cannot bypass an active boundary, and
  subclass TTL overrides cannot defeat its pinned non-expiring policy
- custom serializers cannot remove the strict preparation marker; Smith owns
  checkpoint marker serialization independently of custom state
- duplicate preparation is rejected without another persistence write
- rejected preparation revokes authorization, while ambiguously acknowledged
  preparation remains guarded and non-executable
- execution is bound to the exact transition object captured at preparation
- the prepared transition contract is frozen against in-place DSL mutation
- nested transition configuration is deeply frozen before durable preparation
- `Struct`, `Data`, and `Range` transition configuration is included in the
  contract; opaque mutable objects fail closed; cyclic graphs terminate; and
  oversized, over-depth, or over-byte graphs fail under explicit linear bounds
  without poisoning the workflow object
- checkpointing is bound to the original persistence key and adapter instance
- mutable keys are copied into immutable string identities
- equal mutable checkpoint keys resolve back to the pinned immutable identity
- transactional preparation must be confirmed after commit and cannot execute
  after rollback
- a cryptographic preparation token prevents one workflow object from adopting
  another object's otherwise identical committed payload
- preparation confirmation is compare-and-set and permits one confirmer
- losing preparation and confirmation contenders cannot mutate the winner's
  phase
- an abnormal execution cannot be replayed on the same workflow object
- ordinary execution and checkpoint APIs cannot bypass an active boundary
- reentrant public execution from inside the prepared transition is rejected
- concurrent public execution while the prepared transition runs is rejected
- ordinary execution owns the workflow against concurrent preparation
- preparation owns the workflow before reading transition, key, or adapter
- every active split-step phase serializes as in-progress, including preparation
  intent before its adapter write
- concurrent prepared execution permits exactly one claimant
- unresolved routed transitions retain normal workflow failure handling
- declared handled failure routes remain valid accepted checkpoints
- `dup` cannot copy active split-step execution authority
- the host checkpoints accepted state separately through `persist!` and releases
  the local boundary only after `complete_persisted_step!` verifies the commit
- a rolled-back post-step checkpoint remains guarded; when the exact committed
  preparation is still durable, the same object can retry the unchanged
  checkpoint from the proven preparation version
- checkpoint completion is rejected while its adapter transaction remains open
- checkpoint completion is compare-and-set and permits one completer
- losing completion contenders cannot roll back the winner's phase
- verification phases reject concurrent checkpoints
- rejected persistence targets do not mutate the workflow's cached key
- rejected duplicate preparations cannot mutate the winner's cached key
- subclass method collisions cannot replace Smith's prepared transition
- modules prepended after subclass creation remain behind a fresh Smith guard;
  prepared execution uses Smith's owned `advance!` implementation rather than
  granting transition authority to subclass or prepended wrappers
- every generated subclass guard is frozen before it is prepended, so neither
  publication-time nor later mutation can replace guarded execution behavior
- commit verification uses the exact payload serialized by the persistence
  write, including workflows with stateful serializers

### `spec/smith/workflow/prepared_step_execution_authorization_spec.rb`

Purpose:

- pins the process-local handoff between Smith's durable verification and a
  host-owned executing-attempt transaction

Documented contracts covered:

- authorization performs no transition work and requires the exact active
  preparation or committed dispatch
- structurally equivalent, cross-workflow, copied, serialized, stale, and
  already-consumed capabilities are rejected, including process-fork transfer
- concurrent authorization, release, and execution contenders linearize; a
  losing verifier cannot revoke the winner's authority
- a released capability restores the exact prior boundary, while execution
  consumes the capability once
- durable dispatch loss and definition or transition drift fail before work
- oversized durable payloads fail before parsing or transition work
- mutable registry replacement cannot change the exact authorized agent class
- legacy strict workflows and the compatible one-call execution API retain
  their existing behavior
- prepared parallel and heterogeneous branch workers use the exact captured
  bindings while ordinary subclass branch extension points remain available
- coordinator authority is exact to process, thread, and Fiber; only explicitly
  registered branch Fibers enter the prepared execution membrane
- activation, branch registration, full context restoration, and lifecycle
  cleanup complete before asynchronous `Thread#raise` delivery
- copied or serialized execution scopes and context snapshots are rejected
- all four nested parallel/fan-out pairings restore tool, deadline, ledger,
  result, binding, and artifact context after success, failure, or cancellation

### `spec/smith/workflow/execution_context_spec.rb`

Purpose:

- pins compatibility of the ordinary workflow execution-context lifecycle
  while prepared execution adds stronger isolation

Documented contracts covered:

- setup failures still route through declared transition failure handling
- step and branch teardown hooks run even when their matching setup raises
- agent deadline and tool-call cleanup extension points remain observable

### `spec/smith/workflow/composite_execution_spec.rb`

Purpose:

- pins the host-neutral split execution and ordered reduction contract for one
  prepared same-agent parallel or heterogeneous fan-out transition

Documented contracts covered:

- planning prepares session input once and returns immutable, exact,
  transport-bounded plan and input values tied to the confirmed dispatch,
  executable definition digest, execution-semantics version, and budget baseline
- every branch worker recovers the same dispatch, obtains a fresh process-local
  authorization, revalidates the current branch limit and selected captured
  binding in constant time with respect to branch count, and emits a typed
  success or redacted failure when accounting evidence remains representable
- reduction accepts a complete outcome set in any arrival order, rejects
  missing, duplicated, mismatched, malformed, or replayed evidence, and emits
  canonical aggregate output in declaration order in `O(B + P log P)` worst-case
  time and `O(B + P)` bounded space, with cumulative effects and output rejected
  before authority consumption
- usage, tool captures, budget consumption, and prepared session history merge
  exactly once; duplicate usage cannot partially apply another effect; decimal
  precision, token/cost overflow, and invalid tool captures fail closed
- the host must commit the primary failed branch; per-branch retry is explicitly
  unsupported and Smith does not own scheduling, claims, fences, or persistence
- transport decoders reject unknown fields, excessive size/depth/count, hostile
  Hash/Array traversal overrides, invalid numerics, and branch counts above both
  the transport ceiling and current runtime configuration
- selected branch authorization captures one exact binding in `O(1)` with
  respect to branch count, and the first preparation binds one artifact
  execution namespace shared by every worker and the reducer
- composite execution remains sealed against subclass method collisions,
  arbitrary exceptions cannot forge retryability, failure identity survives JSON
  persistence, and live aggregate output has the same shape as its restored form
- payload construction enforces complete canonical fields and encoded JSON byte
  limits; aggregate budget overrun, known usage replay, and cumulative accounting
  overflow fail before one-shot reduction authority is consumed
- the supported public lifecycle uses scoped prepare, branch execution, and
  reduction calls; authorization-bearing composite methods remain private and
  subclass collisions cannot replace the public framework boundary

### `spec/smith/workflow/composite_hardening_spec.rb`

Purpose:

- pins the adversarial durability and resource-bound guarantees around the
  host-neutral composite lifecycle

Documented contracts covered:

- process-local branch authority binds one exact compact execution envelope and
  cannot be reused for another branch
- stable host-declared agent execution identity rejects implementation
  replacement after planning and is not inherited by distinct subclasses
- restart-safe durable dispatch verification cannot be bypassed through a
  subclass private-method collision
- unknown transport keys do not intern symbols, and arbitrary exceptions cannot
  inject trusted error kind or retryability evidence
- unknown transport enum values do not intern symbols, incomplete persisted
  branch failures fail closed, and cumulative encoded effects stop streamed
  outcome consumption before the complete input is materialized
- asynchronous interruption between branch authorization activation and scoped
  execution releases the exact process-local authority before control unwinds
- enumerated outcomes stop at the first cumulative bound violation rather than
  materializing the remaining stream
- selected worker payload size is independent of the total branch collection
- scalar accounting overflow is rejected before host tool evidence is
  snapshotted

### `spec/smith/workflow/prepared_step_execution_result_spec.rb`

Purpose:

- pins the typed result returned after an authorized execution attempt

Documented contracts covered:

- successful steps and failure-routed steps have explicit, internally
  consistent status and error shapes
- the result owns and iteratively freezes bounded JSON-like step values with a
  cycle-aware `O(V + E)` copy while preserving error identity
- the legacy API receives a separate mutable cycle-aware snapshot

### `spec/smith/workflow/execution_binding_snapshot_spec.rb`

Purpose:

- pins exact process-local agent binding capture for authorized transitions

Documented contracts covered:

- direct, fan-out, optimizer, and orchestrator bindings resolve once
- reachable nested-workflow bindings are included
- nested cycles terminate through identity-indexed traversal rather than
  repeated graph scanning
- reachable nested-workflow definitions are revalidated before child
  construction, so post-authorization transition replacement fails closed

### `spec/smith/workflow/prepared_step_recovery_spec.rb`

Purpose:

- pins opt-in cross-process reconstruction of an exact committed preparation
  without making Smith a scheduler, lease manager, or attempt ledger

Documented contracts covered:

- strict bounded descriptor deserialization rejects malformed, missing,
  duplicated, and unknown transport fields, plus integer counters outside the
  positive signed 64-bit range
- recovery requires a typed `not_started` decision, exact named class and
  schema, matching executable definition digest, exact descriptor identity,
  and the same persistence domain
- ordinary strict restore remains fail-closed and in-progress state cannot be
  migrated before marker validation
- original and reconstructed objects contend through one exact durable claim;
  only one transition body executes
- restart-safe execution rejects an unclaimed preparation; exact claim and
  execution are separate public phases so hosts can atomically correlate their
  attempt ledger before transition work
- exact claim returns an immutable bounded `PreparedStepDispatch` receipt;
  matching durable `dispatching` state can be reconstructed only from that
  receipt plus the host's typed `not_started` decision
- definition identity is pinned at preparation/recovery and drift is rejected
  before claim or execution; the class-local definition identity is sealed so
  concurrent setters linearize before acquisition or fail
- losing same-object claim and confirmation contenders cannot revoke the
  winner's state
- a transaction-coordinated claim is unavailable for execution until confirmed
  after commit, and exact rollback permits a new claim
- missing or same-version-mutated payloads fail closed, and ambiguous dispatch
  acknowledgement cannot be replayed
- a failed post-step checkpoint remains guarded and requires reconciliation;
  an exact durable preparation permits one unchanged retry
- concurrent post-step checkpointing permits exactly one claimant
- checkpoint writes never disarm the in-memory uncertainty marker or expose
  completion before the adapter write returns
- an ambiguously acknowledged checkpoint can be verified without replaying its
  write
- ambiguous checkpoint retries retain one digest witness and cannot issue
  another write before reconciliation, keeping retry bookkeeping constant-space
- reconciled retries must serialize the exact original checkpoint payload
  before Smith dispatches another adapter write
- restore between preparation and acceptance fails closed
- lax and unprepared workflows are rejected; a fresh terminal preparation is a
  no-op while an active terminal boundary rejects duplicate preparation

### `spec/smith/workflow/optimistic_locking_spec.rb`

Purpose:

- pins the optimistic-locking contract: when an adapter supports `store_versioned`, two concurrent processes restoring the same key and racing on persist see the second writer's `persist!` fail with `Smith::PersistenceVersionConflict`

Architecture basis:

- Section 5.3, State Serialization (concurrency control on persisted state)
- Decision #12 (Extend adapter contract additively with `store_versioned`; default fallback to plain `store` with a one-time warning)

Documented contracts covered:

- `Workflow#persist!` increments `@persistence_version` on each successful store (initial 0 → 1 → 2 …)
- the persisted JSON payload carries `persistence_version` so any versioned adapter can read it on the next `store_versioned`
- two restored copies racing on `persist!`: the second raises `Smith::PersistenceVersionConflict` with key + expected/actual fields; the failing workflow's `@persistence_version` stays at the pre-failure value so callers can rescue → restore → retry without state corruption
- `restore` populates `@persistence_version` from the persisted payload (legacy payloads with no key restore to 0 for backward compatibility)
- adapters lacking `store_versioned` fall back to plain `store` + one-time per-adapter-class warning via `Smith::PersistenceAdapters.warn_missing_versioning`; the workflow still increments `@persistence_version` so the in-memory accounting stays consistent

### `spec/smith/workflow/schema_versioning_spec.rb`

Purpose:

- pins the `persistence_schema_version` + `migrate_from` contract: stored payloads carry `:schema_version`; restore dispatches through registered migrations one step at a time; unbridged gaps raise `Smith::PersistenceSchemaMismatch` with actionable diagnostics

Architecture basis:

- Section 5.3, State Serialization (forward-compatible persisted state)

Documented contracts covered:

- `Workflow.persistence_schema_version` defaults to 1; setter rejects non-positive Integer
- `to_state` carries `:schema_version` equal to the workflow class's current `persistence_schema_version`
- restore with stored == current passes through unchanged
- restore with stored > current (downgrade) raises `Smith::PersistenceSchemaMismatch` with stored + current fields
- restore with stored < current and a registered `migrate_from(stored) { |payload| ... }` block applies the block, advances the cursor, continues until current is reached
- chained migrations: stored v1 → v2 → v3 walks via two registered blocks
- unbridged gap (missing `migrate_from`) at any step raises `PersistenceSchemaMismatch`
- defensive cursor advancement: if a migration block forgets to set `:schema_version`, Smith advances it itself so the loop terminates
- pre-versioning payloads (no `:schema_version` key) are treated as v1 for backward compatibility
- JSON-parsed string-keyed payloads are accepted (top-level symbolize precedes migration dispatch)
- `Workflow.inherited` propagates `@persistence_schema_version` + `@migrations` to subclasses
- DSL validation: rejects `migrate_from` without a block, rejects non-Integer versions

### `spec/smith/workflow/seed_drift_spec.rb`

Purpose:

- pins the `seed_validation` contract: persisted state carries a SHA256 digest of the `seed_messages` produced at construction; restore detects when the seed builder has been changed in code since persist; opt-in `:strict` raises or `:warn` logs

Architecture basis:

- Section 5.3, State Serialization (deterministic state replay)
- Section 4.6, Context Manager (seed messages source of truth)

Documented contracts covered:

- `Workflow.seed_validation` defaults to `:off`; setter rejects modes outside `:strict | :warn | :off`
- `to_state[:seed_digest]` is a 64-char SHA256 hex when a seed builder is declared; nil when no builder
- identical builder + identical context produce identical digests; different content produces different digests
- `:off` mode: drift never raises, never logs
- `:strict` mode: drift raises `Smith::SeedMismatch` with `#workflow #stored_digest #current_digest`
- `:strict` mode with no drift: passes through silently
- `:strict` mode with legacy payload (no `:seed_digest` key) or explicit nil digest: skipped (backward compatibility)
- `:warn` mode: drift logs via `Smith.config.logger&.warn`; never raises; silent on no drift
- validation re-evaluates the seed builder against the RESTORED `@context` so context-dependent seeds drift relative to the original construction context
- `seed_digest` round-trips through JSON.generate / JSON.parse
- `seed_message_count` round-trips independently of seed drift validation
- `Workflow.inherited` propagates the seed_validation mode

Notes:

- Default `:off` reflects the reality that many seed builders are non-deterministic (timestamps, UUIDs, request-scoped data) and would surface false drift on every restore. Hosts opt in to `:strict` only when their builder is deterministic.

### `spec/smith/workflow/step_in_progress_spec.rb`

Purpose:

- pins the `idempotency_mode` contract: under `:strict`, `run_persisted!` / `advance_persisted!` stamp a `step_in_progress` marker before each advance and clear it after; restore raises `Smith::StepInProgressOnRestore` when the marker is still set (a previous worker crashed mid-step)

Architecture basis:

- Section 5.3, State Serialization (idempotent resume after worker crash)

Documented contracts covered:

- `Workflow.idempotency_mode` defaults to `:lax`; setter rejects modes outside `:strict | :lax`
- `to_state[:step_in_progress]` is false on a fresh workflow
- `:lax` mode: restore never raises, even with marker set; `advance_persisted!` does NOT stamp the marker (write-amplification-free)
- `:strict` mode: restore with marker true raises `Smith::StepInProgressOnRestore` with `#persistence_key`
- `:strict` mode: restore with marker false (clean step boundary) passes through
- `:strict` mode: pre-advance persist captures `step_in_progress: true` (simulates mid-step worker crash via spy); successful advance clears the marker before post-advance persist
- non-StandardError escape (e.g., SystemExit / SignalException simulation): marker stays set, restore raises
- legacy payload (no `:step_in_progress` key) treated as false (backward compatibility)
- `Workflow.inherited` propagates the idempotency_mode

### `spec/smith/workflow/interrupting_errors_spec.rb`

Purpose:

- pins `Smith.config.interrupting_errors`: errors the host names stop a step as if its worker had stopped, instead of failing it

Architecture basis:

- Errors and Retries (Interrupting errors); Section 5.3, State Serialization (resume after a worker stops)

Documented contracts covered:

- the setting lists subclasses of StandardError, empty by default, deduplicated and frozen; refuses anything else, StandardError itself included
- a step that meets one raises it unchanged: no failure route, no retry, no `last_failed_step`, no `StepFailed`; with none named the same error is retried and routed
- an error raised from one (its `cause`) passes the interrupting error on; durable retries enter no wait
- a lax persisted run takes the step again under the same idempotency key; a strict one is refused on restore (`StepInProgressOnRestore`)
- an agent step whose tool or budget ledger meets one raises it, not `ToolOutcomeUncertain` or `BudgetLedgerError`
- `Parallel.preferred_error` picks an interruption over every error but a process-fatal one; an inline child run's interruption stops the parent's step
- tool batches: no failure handler notification, precedence over a sibling's capture failure, no conversion to `ToolDispatchRejected` from a callback
- a durable composite branch raises it instead of keeping a failed outcome; a batch step's completion through `resume!` raises it and keeps the wait; a parallel step surfaces it; a deterministic step's trace says `:interrupted`
- a tool failure handler that meets one stops the batch with it (per call and for unsettled requests); an interrupted batch notifies none of its unsettled requests with a sibling's error
- `Interruptions.find` checks the error and 15 causes, and never looks through a provider's own failure (RubyLLM, Faraday)

### `spec/smith/workflow/cache_usage_spec.rb`

Purpose:

- asserts that prompt-cache, thinking and response facts flow from a provider response through usage, totals, budgets, pricing, traces and composite effects

Architecture basis:

- Section 4.6, Budgets and Cost
- Section 4.8, Observability

Documented contracts covered:

- `ProviderUsage.from_message` reads cache read and write counts under either RubyLLM reader name and thinking tokens, ignoring counts that are not non-negative Integers; it reads the stop reason and message id of Anthropic, OpenAI Chat Completions, OpenAI Responses (incomplete reason, else status), Gemini and Bedrock Converse bodies, each recognized by its own marker, and nothing from a body without one; facts are bounded; `to_h` omits nil optional members; `sum` totals counts and keeps the last response's facts
- a workflow run records the details on its usage entry, leaves `mode` off an ordinary call's entry, counts cache tokens in `total_tokens` and in a token budget's consumption, round-trips the entry through JSON, and re-serializes an entry without details byte-identically
- `:provider_call`, `:token_usage` and `:cost` traces carry the details; `:cost` adds `cache_unpriced: true` only when cache tokens were priced at 0 for lack of a rate
- budgets and totals settle a completed tool-loop round before a failed attempt, a failed attempt's own cache tokens (entry, cost, totals and budget agreeing with its trace), and the metered part of a partially metered tool loop, whose `:provider_call` carries its last response's facts; a raw body that cannot be read never fails a billed call; `AgentResult#billable_tokens` counts the known parts of half-known usage
- pricing: cache rates, 0 when absent; a tier without cache rates uses the entry's, and never the entry's input or output rate; tier choice on total input including cache writes; String-keyed rates; counts that are not non-negative Integers price as 0; a non-Hash entry is unpriced; `cache_unpriced?`; batch discount, full rate when absent; catalog validation refuses negative, non-Integer-or-Float (Complex, Rational, String, `false`) cache rates under either key form, out-of-range or non-real discounts, and a discount inside a tier
- composite effects accept entries with and without details, total cache tokens, and reject invalid details (negative or Float counts, an empty or over-256-byte response fact, an unknown mode)
- the OpenAI Responses adapter parses a body end to end, reporting input with cached and cache-written input taken out, capping cache counts at the reported input and ignoring non-Integer counts, so the provider's total is kept
- the review fixes above are mutation-verified against the full suite

### `spec/smith/agent/output_integrity_spec.rb`

Purpose:

- asserts that a cut-off, refused or invalid response is never accepted as a step's output, that each is billed, and that the agent's retry, fallback and repair settings are honored

Architecture basis:

- Section 4.1, Agents
- Section 4.4, Guardrails

Documented contracts covered:

- `Smith::Providers::StopReason` reads each provider's cut-off and refusal stop reasons and nothing else; OpenAI's message-level refusals (Chat Completions and Responses) read as `refusal`
- a cut-off response raises `OutputTruncated` (billed), is kept under `on_truncation :accept`, and under `retry_with:` is retried once on the same model with the provider's own limit parameter (Anthropic, OpenAI chat and Responses, Gemini, Vertex AI, Bedrock), never for another provider
- a refused response raises `OutputRefused`, or falls back once to the declared model, never to the model that refused
- a structured output is sent to Anthropic without the constraints it rejects and with closed objects; broken constraints, a non-object output and a failed output contract go back for repair with the rejected reply and the problems, up to `output_repairs`, then raise `OutputInvalid`; JSON text is read as its object; a step with no messages repairs from the rejected reply alone
- `SchemaConstraints` strips for Anthropic only, refuses an open object, and reports problems by path through `$ref`, `anyOf` and arrays, at most 20
- the output errors form the `output_failure` family, are not retryable or caught by `retry_on Smith::AgentError`, persist and restore with bounded details (an unknown class of the family restores as `OutputFailure`), and refuse unbounded details
- the agent macros validate their settings and pass to subclasses
- an agent with no model fails its serial or fan-out step
- these contracts are mutation-verified against the full suite

### `spec/smith/agent/output_integrity_review_spec.rb`

Purpose:

- asserts the output-integrity contracts two adversarial reviews of slice 6 found missing: tool replay, budgets, deadlines, retry limits, repair shapes, contract verdicts, schema shaping and checking, and persisted failures

Architecture basis:

- Section 4.1, Agents
- Section 4.6, Budgets and Deadlines

Documented contracts covered:

- no follow-up call once a tool ran in the step (the step fails with `ToolOutcomeUncertain` around the output error), once the step's reservation is spent, or after the deadline; a failed follow-up raises the pending output error with the provider error as cause and `retry_on Smith::AgentError` makes no more calls; follow-ups count up the attempt index and each rejection leaves an `:output_rejected` trace
- a truncation retry is not made when the response ran out of context or the new limit is not larger than the request had, keeps the larger limit for later repairs, and keeps an OpenAI chat's own `max_tokens` key
- a Gemini prompt block reads as refused, and a Responses refusal wins over its incomplete reason
- a blank structured output stays `BlankAgentOutputError`; a repair after a handoff keeps the continuation turn; checks run after `after_completion`, which a refused response never reaches; RubyLLM's `schema` macro gets the checks and the shaping; a schema Anthropic cannot take is refused before the call (non-retryable) and reported by readiness
- output contracts: empty failures, `false`, Array errors, `true`, JSON text without a schema, unreadable verdicts; schema and contract problems together are capped at 20 and restore
- readiness accepts fallback-only agents in roles that need a model; persisted output failures keep their problems and refuse the wrong family or bad details; composite branch evidence uses the `output_failure` family
- schema shaping strips tuple items and `not`, closes nullable objects and refuses free-form ones; the checker handles decimal multiples, integral floats, numeric duplicates, deep refs, `oneOf`, `prefixItems`, `definitions`, properties beside `anyOf`, and deep alternatives in bounded time
- these contracts are mutation-verified against the full suite

### `spec/smith/workflow/isolation_spec.rb`

Purpose:

- asserts that steps can be isolated from the shared transcript and that untrusted context never reaches injected state or agent inputs

Architecture basis:

- Section 4.3, Context and Sessions
- Section 4.4, Guardrails

Documented contracts covered:

- `session` takes `:shared` (the default, inherited) or `:isolated`; `input:` must be callable and `output_to:` a Symbol
- `input:` replaces the transcript as a step's messages, receives a copy of the context, JSON-encodes structured content, and is refused, with a message naming the fault, unless it is a non-empty Array of at most 100 user and assistant messages with only role and non-nil content; each of a fan-out's branches gets it
- an isolated session shows each agent step only its input, appends no output, injects no state, fails an agent step without `input:` (and graph validation reports it), and asks nothing of a step that runs no agent
- `output_to:` writes the output in the context's key shape and keeps it out of the transcript, shows in graph inspection, and stays within an explicit persist list
- untrusted keys never reach `inject_state` formatters; an agent declaring one as an input is refused at runtime and reported by runtime readiness
- host-admitted system messages are refused; the injected-state marker is recognized only on a system message
- `Smith::Untrusted.wrap` uses a fresh random boundary, escapes look-alike tags and role-label lines, refuses unsafe sources and non-Strings, and replaces invalid bytes

### `spec/smith/workflow/isolation_review_spec.rb`

Purpose:

- asserts the isolation contracts an adversarial review of slice 5 found missing: untrusted keys across nested workflows, the steps after an `output_to:` step, persist-list checks, message roles, and wrapping

Architecture basis:

- Section 4.3, Context and Sessions
- Section 4.4, Guardrails

Documented contracts covered:

- a parent's untrusted keys reach no agent `inputs` at any nesting depth (refused at runtime before any call, reported once as `:nested_untrusted_agent_input`, including when the nested workflow marks the key itself), and no seed builder or nested `inject_state` formatter
- reserved input names are never refused as untrusted; `untrusted :auto` is refused; the untrusted-input diagnostic keeps declared name case
- after an `output_to:` step the next shared agent step gets the continuation turn live and after a restore, and a compute step's `last_output` is the latest step output, in a shared or an isolated session
- an `output_to:` key outside an explicit persist list is refused before any agent call and reported by validation (`:output_to_not_persisted`, `:await_into_not_persisted` for an await's `into:`); `persist :auto` records the key; a fan-out aggregate reads the same live and restored; a step whose result is refused leaves the context unchanged
- an isolated fan-out, optimizer or orchestrator without `input:` is refused at runtime and in validation; an isolated step that runs no agent injects no state; an isolated workflow nesting a shared one draws a warning; an isolated run restores between steps
- route, optimize (generator, and evaluator under `evaluator_context: :inject_state`) and orchestrate run on `input:`, and optimize and orchestrate write `output_to:`
- a callable `evaluator_context:` gives the evaluator exactly the messages it builds from copies of the candidate and the context, checked as an `input:` callable's are (an empty or oversized return fails the step before the evaluator is called)
- the host admits only user, assistant and tool messages; restored session messages and composite input messages must carry a known role
- `Smith::Untrusted.escape` covers every line break, invisible and decorated prefixes, `human:`/`ai:`, full-width colons and look-alike tags; inside a step the boundary is the same for the same step and text and differs across runs, so a durable composite step's wrapped input is prepared identically on recovery
- the review fixes above are mutation-verified against the full suite

### `spec/smith/workflow/child_runs_spec.rb`

Purpose:

- asserts that map, call and spawn steps start runs of their own through the host's launcher, wait for and check their results, and keep untrusted keys and bounds

Architecture basis:

- Section 4.2, Workflows
- Section 5, Persistence and Resume

Documented contracts covered:

- the DSL validates the child workflow, items, `max_items` (1 to 10,000), `input:`, `timeout:`, `into:`, collect and failure modes, refuses unknown or missing options, and needs a timeout route for map and call
- map launches one child per item (ref = index, input, workflow) with the parent key and the wait's token, waits as `kind: :children`, and on resume writes the entries in ref order; `collect: :states` and `:none` write states or counts; a failed child under `on_item_failure: :fail` takes `on_failure` with `ChildRunsFailed` (family `child_runs_failed`, refs and counts persisted)
- results that do not match the children (count, refs, status, extra keys, shape) raise to the host and leave the run waiting
- more than `max_items`, non-Array items, or a non-persisted run with a queueing launcher fail before anything launches; a replay launches the same refs under the same token
- a map's deadline takes its timeout route; a delivery before the wait is stored completes it
- call writes the child's output itself and fails on a failed child; spawn launches and continues
- `Smith::Launchers::Inline` runs children in process and completes the step at once, recording a raising child as failed
- untrusted keys passed under the same name reach the child and persist with it; malformed persisted keys are refused
- graph inspection shows the kind and child; readiness reports a missing launcher and walks the child without flagging its waits
- `Smith::ChildRun.result` builds an entry from a run result
- review fixes: each child's `key` (token and ref) differs across two child-run steps of one run; a spawn taken as a failure route launches; results are checked against the count the step launched (`Wait#children`), not items derived again, and an unpersisted items key is refused; only an `inline?` launcher's return value is taken, and it must be an Array; a strict run that crashed mid-launch launches again; a map or call that fails on a failed child needs `on_failure`, and no map, call or spawn takes `retry_on`; outputs a map does not collect are dropped before the 4 MiB bound, live and inline; a map over no items completes at once; an `await :children` keeps the wait bound; child untrusted key names are checked and symbolized at build; inline children run under the parent's deadline but apart from its tool evidence and attribution, and a waiting, raising or self-handled failing child is reported failed with its error; a spawn launches under a token of its own, from items given a copy of the context, and not past the deadline; a stored wait's children count is checked; readiness flags an in-process nested workflow that maps, lets a durable map recurse, and warns (not errors) of a child agent reading a parent's untrusted key; child inputs are bounded at 16 MiB together as they are built; split-step persistence refuses child-run steps; `ChildRunsFailed` details must add up
- these contracts are mutation-verified against the full suite

### `spec/smith/workflow/inline_child_restore_spec.rb`

Purpose:

- asserts that a child a `call`, `map` or `spawn` step runs through `Smith::Launchers::Inline` is the same run when it is launched again, so a restored parent pays nothing again for what the response memo kept

Architecture basis:

- Section 5, Persistence and Resume

Documented contracts covered:

- a persisted run (its own calls, a call child, a map over two children of the same content, a spawn) cut once the memo has kept any of its six calls restores and finishes with exactly the requests, holds, settlements and usage (its own and its children's) of an uncut run, the same saved context, and every kept call of the steps it runs again found in the memo
- a child's namespace is a version 4 UUID a restore accepts, no two children share one (a call, two map children of the same content, a spawn, an in-process nested workflow's child, the children of a fan-out over two items of the same content, a grandchild), it is the same on every launch from one payload, and another run's are other
- a relaunched child's tools repeat their idempotency keys (a kept reply whose tool had not finished runs it again under its key, a sibling of the same content keeps its own); it reads, lists and deletes what its earlier launch stored as its own; a nested workflow step tried again relaunches the same child (the same namespace), whose call is asked again; launched outside any step, one key names one child
- a nested workflow step tried again by `retry_on` asks its inline child's call again, as it asks the nested workflow's own, so a retry meant to get the child a new answer gets one and a run with a memo ends as one without; a run restored after any of the retried step's four calls was kept takes the step again from its first attempt, replays every kept call through the retry, and sends and ends as an uncut run
- a host launcher's children keep their keys (pinned) and inputs, and each build of one gets a namespace of its own; under a known namespace an inline child's namespace is the version 4 UUID its definition gives from its key, computed in the spec with Digest and JSON alone; an inline child's namespace is no key a step gets (the step's own, its token, its children's keys, or the step's key for a child's key or ref); in another process the relaunched child replays the call the first one kept

### `spec/smith/workflow/child_run_keys_spec.rb`

Purpose:

- asserts that no two children of a run share a `child.key`, wherever their steps run, so a launcher idempotent on the key launches every child, and that a child launched at the run's root keeps the key 0.16.0 gave it

Architecture basis:

- Section 5, Persistence and Resume

Documented contracts covered:

- under a host's own inline launcher idempotent on the key and under `Smith::Launchers::Inline`, the children of a call, a map of two of the same content and a spawn, launched at the run's root and from the same steps in every place an in-process workflow runs (nested twice, each of two items, nested in a nested workflow, nested in each of two items, each of two items of a nested workflow), all have keys of their own and all run; two runs share none
- a host launcher that queues is handed only the run's root children: a nested workflow's or an item's map, call or spawn is refused before launching
- a child keeps its key on every launch from one payload, when a nested workflow step around it is tried again (a launcher idempotent on the key runs it once), and in another process; a nested workflow's and each item's keys are pinned
- a call's, a map's and a spawn's children at the run's root keep 0.16.0's keys (pinned, with their tokens) under a host launcher that queues, a host's inline launcher and `Smith::Launchers::Inline`

### `spec/smith/workflow/host_helper_names_spec.rb`

Purpose:

- asserts that a host workflow defining a method of each name 0.16.0 gave `Smith::Workflow` for image agents and fan-outs over items (27 private methods) keeps it as its own: `Smith::Workflow` has none of them, nor the two constants 0.16.0 added to it, and Smith calls none of the host's

Documented contracts covered:

- with all 27 defined by the host, an image agent paints and its throttle goes to the fallback, a moderation block is a refusal, an answer with no image is an output failure with its usage, a server's error and a lost connection are never sent again, an image agent's tools are refused, and so is an image agent in a streamed or a batch step, and a fan-out over items runs one nested run an item within its share of the budget, a refused run its item's outcome, and nothing for no items (Unreleased)

### `spec/smith/first_use_spec.rb`

Purpose:

- asserts that a lock Smith shares across a process is made when Smith loads, never on first use: in a fresh process, with the first thread to make such a lock held until a second makes one, threads that first resolve the artifact store or ask for the persistence adapter together build one and each gets it, and threads that first use the agent registry together are held by one lock; an artifact store or persistence adapter whose construction asks Smith for itself fails with a `Smith::Error` saying so, never Ruby's recursive locking (Unreleased)

### `spec/smith/host_constants_spec.rb`

Purpose:

- asserts that a bare constant in a host's Workflow, Agent, Context or Tool subclass (its class body, methods, `def self.` and `class << self`) finds the host's own top-level constant of each name 0.16.0 let it find Smith's (`ImageRequest`, `PaintInput`, `PaintedAnswer`, `ProviderPaint`, `MODERATION_BLOCKED`, `NestedItemsExecution`, the private `Envelope`, `Painted` and `Unkept`, and `MEDIA_TYPES` in an agent's `class << self`), and of the names its fixes gave Smith

Documented contracts covered:

- every constant, public or private, held by a module those four classes include or extend, on the instance side and the class side, and every private constant of the classes themselves, is one 0.15.0 held (private ones looked for by every name Smith's lib defines or marks private) (Unreleased)

### `spec/smith/artifacts/durable_stores_spec.rb`

Purpose:

- asserts that the artifact store is configured like workflow state, and that the S3-compatible and Active Record stores keep artifacts with the runs that stored them

Documented contracts covered:

- `artifact_store` resolves a named store (`:s3`, `:file`, `:active_record`, `:memory`, as Symbols or Strings) with `artifact_options`, a store class built with them (and validated), a class or module that stores itself, or a store (needing `store` and `fetch` only), and caches it, built once under a lock, until the store (by identity) or its options change, keeping a `:memory` store across a `test_mode` change; an unknown or incomplete store is refused; with nothing configured, `Smith.artifacts` raises `Smith::ArtifactStoreMissing` outside `test_mode` and is an in-process Memory store in it; a run that keeps no artifacts needs none, and a step that stores one fails with it; `:s3` explains that it needs the SDK or a client
- the S3 store keeps one object per artifact under its prefix, with its content type and the run that stored it, reads none for a missing, malformed or other tenant's ref, lists expired refs across pages and by run, deletes, and passes on errors other than a missing object
- the Active Record store keeps one binary row per artifact with its run, by model class or name, refuses malformed and other tenants' refs, lists expired refs by run, and deletes
- a run's documents read back through both stores; a scoped delete removes only the run's own refs and is refused over a store that cannot vouch for refs; `workflow.artifacts` lets the host read and clean up a run's refs after the run, and refuses non-String refs
- these contracts are mutation-verified against the full suite

### `spec/smith/doctor/checks/artifacts_spec.rb`

Documented contracts covered:

- `smith doctor` warns when no artifact store is configured, fails when it cannot be built, passes a durable one, and warns of a process-local store beside persisted state and of a store that cannot say which run stored a ref

### `spec/smith/artifacts/store_rules_spec.rb`

Purpose:

- asserts the rules every built-in store (Memory, File, S3, Active Record) keeps

Documented contracts covered:

- each stores bytes only (a `TypeError` otherwise), takes a tenant namespace of letters, digits, `-` and `_` only, and keeps to `artifact_tenant_isolation`
- each names a run only for a ref that run stored, never for no run, and never for another tenant's ref
- tenants stay apart in fetch, `stored_by?`, `expired` and `delete`
- `expired` uses `artifact_retention` when no retention is given and lists by run; `delete(ref, execution_namespace:)` removes only what that run stored
- Memory keeps each run's claim on shared bytes apart: a run's delete drops its claim, the bytes go with the last, and expiry goes by the claims' times
- a File store deletes nothing outside its directory; an S3 store treats only keys of its ref shape under its prefix as artifacts (not a sibling prefix, a stray key or another tenant's), keys an empty prefix without a slash, takes a client or its options, and raises errors other than a missing object; an Active Record store deletes only its own well-formed refs

### `spec/smith/artifacts/ownership_spec.rb`

Purpose:

- asserts that a run reads only the artifacts it, or a run whose namespace it may read, stored

Documented contracts covered:

- Memory and File stores answer `stored_by?`, and a scoped read asks them: another run's ref, under its own prefix or the reader's, and a guessed content hash read nothing; a child that may read its parent's namespace reads its refs
- a File store reads no ref with a path, dot or NUL, nothing outside its directory, and no other tenant's ref
- identical bytes stored by two runs share an inner ref, and each run reads it only once it stored it

### `spec/smith/content_parts_spec.rb`

Purpose:

- asserts that `Smith::Content` parts and `Smith::Message` messages reach providers in their own forms, from `input:` and `seed_messages`, and stay data everywhere else

Architecture basis:

- Section 4.3, Context and Sessions

Documented contracts covered:

- parts are frozen and closed: text (1 byte to 1 MiB), documents (`application/pdf`, `text/plain`) and images (png, jpeg, gif, webp) by artifact ref (at most 1 KiB), `cache` only as true; anything else is refused
- messages keep String content plain and mark parts with `"parts" => true`; a system message takes text parts only; 1 to 100 parts; roles system, user and assistant
- an agent step's `input:` gives Anthropic native blocks (base64 PDF or image, `text/plain` as text, `cache_control` on cached parts) and other providers the joined text with attachments; a missing artifact, a ref of another run, an artifact that is too large, more than 4 cache points on Anthropic, or a system message in `input:` fails the step before the call
- seed messages keep their parts, reach Anthropic's system blocks cached, restore, and keep their digest; a restored session refuses parts outside the seed messages or malformed ones; `append_session_messages!` refuses parts; an output shaped like parts reaches the provider as JSON text; hand-built parts messages are checked in `input:` and `seed_messages`
- a child run, restored from job arguments or run inline, and a grandchild read the documents their ancestors stored; an unrelated run's ref reads nothing, and a parent cannot read its child's; inherited namespaces are bounded (nearest 16), checked at build and on restore, deduplicated and persisted; a step's artifact scope ends with the step
- review fixes: refs follow a closed format and are read only from a store that records which run stored them, so a crafted, guessed or another run's ref, or a path outside a file store or another tenant's, reads nothing; only user messages and only `input:` take documents and images (seeds, system and assistant take text); parts are UTF-8, non-blank, Symbol-valued or not, and the `"parts" => true` marker alone marks a parts message; restored seed parts work however the payload was parsed; documents are read once per call, checked against their media type, empty or oversized ones (5 MiB images, 24 MiB documents) and requests past 32 MiB as sent refused with `Smith::ContentUnavailable`, and a store error is that error, not a provider failure; cache points count the chat's own and every Anthropic model in the chain; other providers get parts in order with attachments named in place and `text/plain` inline; a model that takes no such content passes to the next; RubyLLM content found in a session goes as text
- these contracts are mutation-verified against the full suite

### `spec/smith/streaming_spec.rb`, `spec/smith/streaming_review_spec.rb` and `spec/smith/streaming/json_field_spec.rb`

Purpose:

- asserts that a step declared with `stream:` sends its reply's text to a per-step host sink as the model writes it, withdraws text Smith discards, and changes nothing else

Architecture basis:

- Section 4.3, Context and Sessions; Section 7, Observability

Documented contracts covered:

- `stream:` takes a Symbol and is refused on a parallel step; graph snapshots and contracts carry it; sinks are a Hash of callables by Symbol or String name; readiness reports a missing sink and, under `openai_api_mode: :auto`, an agent with tools whose static, fallback or inferred model is OpenAI
- the sink callable gets the step's frozen info (`stream`, `execution_key`, `transition`) once per step execution; a nil sink streams nothing and a raising callable is logged by class and the step goes on unstreamed; a step without `stream:` calls its chat without a block
- a sink hears `start` (with attempt, model, provider) per provider call, `delta` per text chunk (no thinking, nothing empty), `reset` before a call that replaces the text (`:truncation`, `:repair`, `:fallback` after a refusal or a provider failure, `:retry` before the step's next attempt), `reset(:retry_wait)` when a durable retry waits (its resumed attempt streams to a new sink), `finish` with the output after `after_completion` and `output_to`, and `fail` with the error's class; an unregistered sink fails the step before its call; a raising sink is logged by class only; only the methods a sink defines are called; a session sends nothing outside a start and settles once
- stop reasons and message ids come from RubyLLM's own chunk builders for Anthropic (a new message clears the last one's stop reason), OpenAI and its subclasses (choices, refusal deltas), OpenRouter, Gemini (finish reasons, prompt blocks) and Bedrock (flat and nested), collected only inside a call, nested collections kept apart, bounded, never raising; the observer is installed once per module and inherited; a streamed reply's facts win over its raw body's, and without a stop reason its output reaching the request's limit counts as cut off (`output_limit_reached`), the limit read from the request
- over a local server, RubyLLM's real Anthropic, OpenAI Chat Completions and Gemini streams reach the sink, with a cut-off Anthropic reply retried at a larger limit, an OpenAI cut-off and a Gemini refusal read from the stream; Smith's Responses path sends one delta and keeps its body's stop reason, and passes no empty chunk
- `JsonField` returns the field's growing text only when a piece adds to it, unescapes every JSON escape split anywhere (surrogate pairs; lone halves and bad `\u` escapes as U+FFFD), skips text before the object and strings that are not the key, reads only the first object's top-level string value, and starts over on reset
- review fixes: each streamed response's usage entry keeps its stop reason, message id and `mode: :stream` (a tool loop's rounds apart, a failed call's completed rounds too), as an unstreamed step's does; only the step's own provider is read, so a tool's own streamed call cannot change the step's stop reason; a real stream that ends before its stop event fails as cut off (`stream_incomplete`); `<think>` text never reaches the sink, split across chunks or not, per request; `finish` waits for the step to be stored, and a failed store gives `fail` with its error; a sink or callable raising a `ScriptError` is logged and the step goes on; the sink gets a frozen copy of the execution key; a durable retry that waits before any call still ends the sink with `reset(:retry_wait)`; Gemini's public `build_chunk` stays public; readiness's Responses warning follows runtime routing (thinking, tool compatibility, an `openai_api_mode` param, block-given tools) and no longer warns for a plain tool; `JsonField#push` returns only the added text, reads escaped keys, and takes a later string member after a non-string one; collection lives in fiber storage, read from child fibers
- these contracts are mutation-verified against the full suite

### `spec/smith/batch_spec.rb` and `spec/smith/providers/anthropic/batches_spec.rb`

Purpose:

- asserts that a step in batch mode sends the exact request a synchronous call would post through the host's queue, waits, and takes each result as the reply it would have got

Architecture basis:

- Section 4.3, Context and Sessions; Section 6, Budgets; Section 7, Observability

Documented contracts covered:

- `mode:` takes :sync, :batch or a callable (of the context, or the context and the attempt), needs `on_failure`, is refused with a stream or on a parallel step, works on `fan_out`, and shows in graph snapshots and contracts; readiness reports a missing queue and an agent with tools or a non-Anthropic model (an error for :batch, a warning for a callable)
- sending captures RubyLLM's own payload (model, messages, `stream: false`) and the call's headers, frozen, under the wait token as `custom_id` and the run's execution key, makes no HTTP request, and stores a `:batch` wait and `pending_batch`; a missing queue, a provider without a batch interface, tools, or split-step execution fail the step before anything is queued
- completing takes the result through RubyLLM's parser into `output_to`, with usage `mode: :batch`, its stop reason and message id, priced with `batch_discount`; a follow-up repair goes over the wire; a refused request fails without retry; a failed result is retried in process under a new token, or synchronously when the mode callable says so, or after a durable retry's backoff; a wait past its deadline fails as missing; a delivery naming other ids, an unknown result type, a succeeded result without its message, a non-Hash or non-JSON payload raises ArgumentError and leaves the wait, and a wrong event or token is stale; a result that comes after the budget ran out is still charged
- a fan-out captures each branch's request in its branch, under ids derived from one token, waits once, and gives each branch its own result and usage entry
- restore refuses a malformed pending batch, a wait whose request count or event no longer matches, and a step no longer in batch mode
- the Anthropic client submits one batch with the shared headers and the provider's key, refuses mixed headers, other providers, empty or oversized batches before sending, reads status and the JSONL results file, cancels, refuses a malformed batch id, and makes no connection retries
- these contracts are mutation-verified against the full suite

### `spec/smith/response_memo_spec.rb`

Purpose:

- asserts that a step replayed after its process died reuses what its provider calls got instead of paying again

Architecture basis:

- Section 5, Persistence and Resume; Section 6, Budgets

Documented contracts covered:

- a call kept as complete is replayed without a request: its reply is the step's output, its usage (counts, stop reason) is recorded once, and its `:provider_call` trace says `memo: true`; the replay fetches the keys it stored
- a tool loop kept part way continues from its tool results: the tool runs once, the resumed request carries its result, and every round's usage is counted once
- a step cut while its tools run keeps the reply that called them (version 2, before they run, with its stop reason and message id): replayed, that reply is not asked for again, its tools run again under the same idempotency key, the next request carries their results and is a later round on the budget ledger (reconciled, not held, as the step cannot pause), and each round's usage is counted once; a streamed step keeps that reply's stream facts and streams only the live rounds
- a streamed step replaying a kept reply gives its sink the text in one delta and sends nothing
- a streamed answer kept whole (its record holding an empty list of tool calls, as 0.16.0 kept it) is replayed after a restore: nothing is sent, the sink gets the kept text in one delta, and its usage is recorded once
- a memo whose `fetch` or `store` raises is logged by class and the request goes on; a record not of the shape Smith keeps is ignored (a record kept whole that ends on a reply calling tools, a tool result, or a user turn is refused, and the call sent); a memo without `fetch` and `store` is refused when set
- a call's key names its attempt, model candidate and place among the attempt's calls; a batch request is not memoized
- these contracts are mutation-verified against the full suite

### `spec/smith/response_memo_review_spec.rb`

Purpose:

- pins what a review of the response memo found

Architecture basis:

- Section 5, Persistence and Resume; Section 6, Budgets

Documented contracts covered:

- a structured (`output_schema`) reply is kept and replayed as itself, its stream sink getting its JSON text
- a replayed streamed reply keeps its stop reason, so a cut-off one fails the step as it did
- a parent's retry around a nested workflow makes, pays for and records each attempt's child call once
- a replayed loop refused at its first live round keeps its kept tool results in the pause's continuation; one paused at a later live round keeps every round's messages
- after a replayed tool loop, a failed live round fails with `ToolOutcomeUncertain` and no fallback runs the tool again
- a replay whose request changed (the model, or only the agent's instructions) misses and is sent; a call that cannot be kept is logged
- a complete record that does not end in a model reply, or of another version, is ignored
- these contracts are mutation-verified against the full suite

### `spec/smith/response_memo_pending_review_spec.rb`

Purpose:

- pins what a review of keeping a reply before its tools run (0.12.2) found

Architecture basis:

- Section 5, Persistence and Resume; Section 6, Budgets

Documented contracts covered:

- kept tool results are charged to the agent's `tool_calls` allowance (by tool name for an exact budget) and to the workflow's `tool_calls` budget, with or without an agent allowance, so the replay offers and runs no more tools than the run did; a kept record past a lowered allowance charges what it can and goes on without tools
- a reply calling a tool its request did not offer (a budget finalization) is not kept, so a replay fails as the run did without running that tool
- only a record ending in a reply whose tools have not run is version 2; the rest stay version 1
- a call a tool halted keeps only its progress, which a replay answers from without a request or a fetch error
- a record whose tool results do not answer its replies' calls (unanswered, unknown or repeated results, a reply before the last one's results, in a complete record too, an unfinished one ending in a plain reply, a user message carrying calls) is ignored and the call is sent afresh
- a tool's description and parameters are in the request digest, so a call kept before a tool changed misses
- a streamed call that fails after kept replies gives each kept reply its own facts and each live reply its round's, none the failed round's
- these contracts are mutation-verified against the review fixes


### `spec/smith/billing_refusals_spec.rb`

Purpose:

- pins that a provider's refusal for want of credit is a payment-required error, whatever its status (0.12.4)

Architecture basis:

- Section 6, Budgets; interrupting errors

Documented contracts covered:

- Anthropic's 400 "credit balance is too low" stops a step as an interruption when the host names `RubyLLM::PaymentRequiredError`, the error RubyLLM raised as its cause, and records no failure
- a usage-limit refusal fails a step whose host names none, its source error a `RubyLLM::PaymentRequiredError`
- Anthropic's monthly spend cap (429, `enforced_spend_limit_reached`) is one
- a streamed request's refusal, raised by RubyLLM as a `RubyLLM::ServerError`, is one
- OpenAI's 429 `insufficient_quota` is one; a 429 whose message speaks of a quota without that type stays a rate limit
- any other 400 stays a `RubyLLM::BadRequestError`, one that quotes a refusal's words mid-message too
- a candidate's refusal outlasts a fallback on another account that then fails another way: the step waits
- `Batches#submit` raises a refusal as one and any other error as it is
- these contracts are mutation-verified against the review fixes

### `spec/smith/workflow/renamed_restore_spec.rb`

Purpose:

- pins that a workflow can rename a state or a transition and keep its persisted runs, under the keys they had (0.12.7)

Architecture basis:

- Persistence and durability (docs/PERSISTENCE.md): restore, waits, idempotency keys

Documented contracts covered:

- a run persisted in a renamed state, about to take a renamed transition, or waiting in one restores under the new names and carries on, each name kept the type it was persisted as, a last failed step's names included
- a run whose last failed step and both its states were renamed restores and takes the step's `on_failure`, or reads back its failure once it ended failed, in lax and strict modes through every shipped store adapter, a record as 0.13.0 stored it included (the restore itself, not only the mapped names)
- renames chain; a name the class still declares is never taken for an old one; a rename to an unknown name is still refused on restore
- a name renamed twice or back to a name it had, a blank name, and two names renamed to one transition are refused where declared; two states may be renamed to one
- a renamed transition keeps its keys: a step cut short, a durable retry's next attempt, a delivery that came before its wait was stored, a map's relaunch and a spawn's relaunch all meet the keys they had before the rename
- `current_state_name`, `current_transition_name` and `transition_key_name` follow renames; `stuck_for?`'s terminal check follows them too
- subclasses inherit their parent's renames and keep their own
- `validate_graph` reports a rename leading nowhere as an error and one whose old name is still declared as a warning
- every guard and key site is mutation-verified

### `spec/smith/agent/prompt_cache_spec.rb`

Purpose:

- pins `prompt_cache :automatic`: a top-level `cache_control` on an Anthropic request over the wire alone, never a batch request, inherited, refusing another mode, and counted among the four breakpoints with a top-level marker the chat already carries, three marked parts sent and four refused (Unreleased)

### `spec/smith/attempt_observation_spec.rb`

Purpose:

- pins the experimental recorder seam: one observer per process; an empty slot read once per provider attempt and nothing called; an installed observer never called outside a trial and handed one frozen attempt per provider attempt inside one, read where it ran; an empty slot read once on a failed attempt too, an image's throttle on its way to the fallback; an image agent's attempt (it paints, never passing `ProviderCompletion#attempt_model`) observed once, as its one `:provider_call` trace, a throttled one and its fallback each once, its record the request's text as sent and its settings and a reference to the image that came back (MIME type, byte size, SHA-256 digest), never the image's bytes, an image that came back and could not be kept described as a kept one is, no `RubyLLM::Image` alive past its attempt (none during `after_completion`), and a moderation block's record the request alone, its settings and media type those the agent declared with `image`, whatever its own `image_request` and `image_media_type` answer; Smith's failure kinds in order, with fixed words for a refused key, account or model; an observer or logger that raises never changes a step, and the logger gets the error class only; an observation frozen only at its top, its messages holding the chat's own objects; the seam's names never shadowing a host's constants in its agent, workflow or tool classes; `Attribution::Context#trial` last and optional, out of `to_fields`; `AttemptObservation::Transcript` offering `messages` and `painting` alone and reading no attachment's bytes (Unreleased)
- pins each attempt's start (where its timed provider call started, on the monotonic clock its duration is measured on; none before a call or for a skipped candidate), each provider response's tokens and mode (a tool loop's rounds, completed or failed part way, as its usage entries hold them; an image's image tokens), and the settings its request carried, read from the request as sent against the local server's request body: whatever RubyLLM's renderer left out left out (gpt-5's budget alone, claude-sonnet-4-5's effort beside a budget, effort none, a search model's temperature) and params included (a temperature or reasoning effort, a String key beside RubyLLM's Symbol), Gemini's, OpenRouter's, Bedrock's (a budget, or an embedded model's effort) and DeepSeek's (as OpenAI's) own names, a batch step's from the request its delivered result answers, none for a request never sent (one its renderer refused, one JSON could not write) and none for one the seam cannot read, which never raises into it; nothing kept on RubyLLM's provider objects; requests read only once an observer is installed (a fresh `require "smith"` leaves `RubyLLM::Connection` as it is), each then reading the slot once more and calling nothing without one; the out-of-credit words naming no status, for a 429 refusal too (Unreleased, slice 1a.4)

### `spec/smith/core_invisibility_spec.rb`

Purpose:

- the shared "no difference" harness: the forty-four scenarios of `script/core_invisibility_golden` (an image agent, a fan-out over items, steps that end failed with their failure records, orchestrate over String-keyed replies and restored after a kill among them, and every way a paint can fail, be refused, be held or be retried, image agents by inheritance, fan-outs over items refused, failing, empty, within a budget, retried, after a wait and painting, and what moving to RubyLLM 2.x changes without an error: a request with no output cap, cached instructions, the automatic cache, a truncation retry, an OpenAI model that reasons, a streamed reply cut at its cap, a paused tool loop that thinks, a refusal past a spending limit, a connection dropped once the request was sent and a memo replay of a reply that read and wrote the cache), every artifact store call recorded, the golden written from a commit or the staged index, never an unstaged edit, in a bundle of its own from its parts extracted by their git ids (the header names `lib`, the gemspec, the harness and the local server by id, and the commit they were built on, and never the golden itself; a folder with a part changed, added to or taken from, code in its Gemfile, an unknown id or commit, or a working tree refused; the golden bundle handed the gems the suite sees, a vendored bundle's included), written again from the ids it names byte for byte under the same `Gemfile.lock` (the golden bundle resolves its versions; skipped with its reason in a shallow clone, or while its source is an uncommitted change; a full repository whose HEAD does not reach every id fails, though the objects are in it, shown in a repository of the example's own so it runs in a shallow clone too; a file written again is compared in every block but the versions), run on the tree in child processes, equal the golden file byte for byte without an observer, with one installed and no trial, and inside a trial (no extra random draw, one observation per `:provider_call` trace), and the observer and trial modes equal the plain mode sink by sink; `--diff` names what differs between two goldens, header part by part and scenario by scenario; a concurrent run of the parallel, fan-out and fan-out over items scenarios matches by counts and branch content; the host surface of Workflow, Agent, Context and Tool (method names, Object and Kernel names they override, constants a host's class body can see) equal to the golden's; against the release baseline (`spec/fixtures/core_invisibility_release.json`, 0.16.0's lib and gemspec with a91fd45's harness, written again from the ids it names byte for byte and named by the commit its release tag names, the tag check skipped with its reason in a clone without the tag and failing when the tag names another commit), which no golden regeneration writes, the host surface and each scenario's random draws, lookups, requests, traces, events and log lines differ only as the spec lists, each with why and its slice, a method a slice adds named `smith_` or a listed DSL macro, nothing removed but the 27 private methods and two constants 0.16.0 added to `Smith::Workflow` and the four constants it added to `Smith::Agent`, each listed with where it went, and no other name allowed to go (Unreleased)
- the golden bundle installs with a gem home and settings of its own, so it never waits on the lock in the shared gem home (Unreleased)
- the prompt seam beside agents that declare none (slice 4): the `prompted` mode, with an agent in the process declaring a named prompt and a prompt registry set that refuses every call, equals the golden in every scenario and the host surface; the one name the seam adds, `Smith::Agent.smith_prompt`, is listed against the release baseline (Unreleased)
- the trial, concurrent and credentialed modes record through the real recorder (`smith/evals` loaded, each scenario under `Smith::Evals.under` with a `Smith::Evals::Recorder` attached), still equal to the plain mode sink by sink and host surface for host surface; one step record per `:provider_call` trace, where it ran and how it ended, each valid against the trial schema's step, open and strict (Unreleased, slice 1a.4)
- run credentials on every path (slice 1c), on the tree against its plain mode: with every workflow declaring `provider_credentials` and no key in RubyLLM's global configuration, every scenario's records equal the plain mode's but for the saved empty scope and the one RubyLLM context each credentialed run builds, every request carries the run's key, a batch request is queued with the run's (empty) scope, and each provider attempt is observed once inside a trial; with `require_run_credentials` on and nothing declared, no scenario sends a request, asks a ledger, makes a provider call or records usage, and each fails with `ProviderCredentialsMissing` (Unreleased)

### `spec/smith/ruby_llm_pins_spec.rb`

Purpose:

- pins, through RubyLLM's own provider code against the local stand-in server, what Smith does on RubyLLM 1.16 where moving to 2.x changes it without an error: a response's usage recorded with its cache reads and writes and thinking; a held request settled on the host's ledger at what it spent, not at its hold; the hold's output cap equal to the cap the request sends, the agent's own, and 4,096 held and sent when it sets none (a move to the 128,000 RubyLLM 2.2.3 lists is a decision to state); a truncation retry sent with the larger cap; an OpenAI reasoning model's cap sent as `max_completion_tokens`; `prompt_cache :automatic` in the request body and the hold priced as a cache write; an image request held at the 823 tokens its size and quality write, priced, and, its answer timed out, never sent again and charged that hold; a text request whose connection drops going to its fallback model, and one with no fallback left or whose answer timed out leaving the step its retries (`Smith::AgentError`); Anthropic's spend cap, sent as a rate limit, arriving as `RubyLLM::PaymentRequiredError`, so a host can wait for credit; `Smith::Testing` stubs answering plain and streamed calls as the agent's model with no request; a response memo replaying a kept reply that read and wrote the cache, or reported zeros, without sending it again, its counts kept; an agent on a model id RubyLLM's list aliases sent, recorded and priced under the id it names; a batch step handing its request to the host's queue, sending nothing, and taking the delivered result as its reply; a run restored from a budget pause sending back each message's thinking and the provider's tool call ids, its restored messages keeping their model; a streamed reply ending at its cap read as limit reached, and one stopping at `max_tokens` as that, each with its usage; a streamed refusal kept as `refusal`, and a reply a full context window cut off never retried with a larger cap; with no cap on a model RubyLLM lists, a streamed reply read against the model's own limit and a cut-off reply never retried with a smaller cap than it was sent with. The RubyLLM names they use are marked, for the 2.x slices to rewrite (Unreleased)

### `spec/smith/contracts/ruby_llm_spec.rb`

Purpose:

- the prompt seam's touch point: an agent's instructions block runs as its chat is built, in the building fiber, with its inputs as methods, and is copied to subclasses (Unreleased)
- RubyLLM's public touch points Smith relies on, through its public interface only: the message, content, tool call, thinking and attachment readers the transcript uses, a paint's `RubyLLM::Image` and its base64 `data`, a schema reply parsed into a Hash, the `*_api_base` options, and one public error class per provider status (Unreleased)
- where a request leaves for its provider (slice 1a.4; the listed exception, pinned to 1.16 and replaced at the 2.x move by `chat.render` or a `before_request` callback): each request's payload, its params merged in, posted through its provider's `RubyLLM::Connection#post(url, payload)`, whose `provider` reader names the provider, and the provider class's `slug` (Unreleased)
- run credentials' touch points, listed in `Smith::ProviderOptions`, the upgrade gate for the RubyLLM pin: an isolated `RubyLLM.context` (two contexts send their own keys, the global is unchanged), `RubyLLM::Agent.chat` passing `context:` through, an agent class's own `context` and `inputs` readers, every registered provider's options classified in `ProviderOptions::TABLE` and its credential named in `ProviderOptions::CREDENTIALS`, a context with no instrumenter emitting nothing, the logger RubyLLM logs with (`config.logger`, else a Logger at `log_level` as an Integer, Symbol or String, kept once used) writing bodies at DEBUG, `log_stream_debug`, an error copied through its public constructor and read as before, an Anthropic message parsed on its chat module with no provider or key, and the model registry's provider for an unqualified model (Unreleased)

### `spec/smith/contracts/run_credentials_providers_spec.rb`

Purpose:

- every provider RubyLLM registers, under run credentials, with fake credentials planted wherever a provider library finds its own (the environment, cloud SDK files, RubyLLM's global keys and endpoints, Google's application default credentials through a googleauth stand-in, `spec/fixtures/googleauth`): each sends only what the run names (its key, its service account's token, a signature naming its access key id; nothing for a local Ollama or GPUStack), nothing to a global endpoint; under the fail-closed mode a run without credentials is refused before anything is sent, and an uncovered provider is skipped; a service account key without its project (which googleauth would complete from the worker's gcloud) refused before googleauth is asked; RubyLLM itself, given a context with no credential, finds one of its own (Vertex AI) only for a provider whose credential `ProviderCredentials` requires, and only a local provider is accepted without one (Unreleased)

### `spec/smith/run_credentials_spec.rb`, `run_credentials_paths_spec.rb`, `run_credentials_fail_closed_spec.rb` and `run_credentials_canary_spec.rb`

Purpose:

- pins run credentials (a workflow's `provider_credentials`, additions design section 3): nothing loaded on `require "smith"`; the scope captured from the trusted context as a `Smith::Scope`, saved only by a declaring class, restored, the block asked with it once per run per process (16 parallel branches, a restore in a fresh process); requests on the run's key and endpoint alone, a context clearing every secret and endpoint and keeping other settings; an uncovered candidate skipped and observed (one observation per trace plus one per skip), never a global key sent; `ProviderCredentialsMissing`, `ProviderCredentialsRefused` (401 `key_refused`, 403 `permission`, kept by class on restore) and `ProviderCredentialsError` with Smith's own text, a 402 on today's class path that still interrupts, a 401 asking the block again at the next step; errors scrubbed first (`ScrubbedError` with no cause, an unheld error the same object), a run without credentials seeing the very errors it saw before; nested and child runs; RubyLLM's instrumentation off for credentialed runs; anything raised while a credentialed failure is handled (a chat's or a paint's) caused by the scrubbed error, never the original; an error whose cause or `inspect` alone holds the key scrubbed, one holding an address beside a Vertex AI service account key left alone, and a transport failure still a transport failure, so its fallback runs; a global endpoint the run names none of never used; a restore taking its saved scope over its context; the step's own error when only uncovered candidates are left; an unkept image's usage recorded and its store's error scrubbed with no cause; a batch result's usage read with no global key, the queue given a credentialed run's scope, `Batches.new(credentials:)` submitting on them and refused its global default under the mode; a nested class scoped by its items' key refused, at run time and in readiness; Smith's own check's refusal passed on in `ProviderCredentialsError`; a scrub that fails giving a `ScrubbedError` with no cause; `Batches.new(credentials:)` keeping no global endpoint or instrumenter; the fail-closed mode, readiness (a class that asks no agent ready, a parent never judged by its nested or child classes, RubyLLM's logger at DEBUG in every form, with the reason; cloud credentials found on the machine, gcloud's own login among them, by name) and the doctor (the same, and each loaded workflow class that asks an agent without a declaration, a nested-only one aside); and the canary matrix, the key in no saved payload, result, usage entry, trace, event, log line, stream or batch delivery, error chain, failure record or `workflow.inspect` while the wire shows it sent, and no RubyLLM configuration, context, chat, provider or connection, nor any String holding the key, reachable from what a run keeps (its binding aside), a batch capture that fails among the paths (Unreleased)

### `spec/smith/provider_credentials_spec.rb` and `provider_credentials_scrubber_spec.rb`

Purpose:

- pins `Smith::ProviderCredentials` (each provider's own secret and endpoint options and the credential it sends, a Vertex AI service account key among them, with its project, checked and scrubbed by its secret parts, secrets of 16 bytes or more, a key put where a provider or an option is named never shown, printed by provider name only, refusing JSON, YAML and Marshal) and the scrubber (any 12-character window of a value removed, however often it occurs, as written, JSON-escaped or URL-encoded, an 11-character run kept, a value under 16 bytes refused, the text's encoding kept) (Unreleased)

### `spec/smith/canonical_json_spec.rb`

Purpose:

- pins `Smith::CanonicalJSON` (RFC 8785): every number of the RFC's Appendix B as Node.js writes it, but the five it writes as integers past 2**53 - 1, which it refuses, NaN and Infinity refused, members in UTF-16 order (the RFC's sorting and full examples), JSON.stringify's escaping, keys equal after Symbol conversion, integers past 2**53 - 1, Floats it would write as one (1e20) and invalid UTF-8 refused, what it writes reading back as itself, and the depth, value and byte bounds (Unreleased)

### `spec/smith/json_value_spec.rb`

Purpose:

- pins the strict JSON reader evals and definitions share: a number only when canonical JSON writes it and reads it back as itself (1e20 and integers past 2**53 - 1 refused), and an escaped half of a surrogate pair alone refused whatever the json gem reads (Unreleased)

### `spec/smith/scope_spec.rb`

Purpose:

- pins `Smith::Scope`: a frozen Hash of at most 8 String pairs with keys like "tenant", values of 1 to 256 bytes of UTF-8, Symbol keys converted, everything else refused with `Smith::ScopeInvalid` that never names a value, and a digest stable across processes and equal to the reference generator's (Unreleased)

### `spec/smith/evals/statistics/*_spec.rb`

Purpose:

- pins `Smith::Evals::Statistics` against `spec/fixtures/evals/statistics_reference.json`: the distributions at 1e-9 relative, the closed forms at 1e-12, SplitMix64, its range draws and the seeded bootstrap exactly; the design-effect, interval-inversion, Holm, size and display cases; the no-worse family at 1 - alpha/m; every input bound refused before any work; every result valid against `docs/evals/schemas/stats.schema.json` as published and with unknown fields refused; the design's property tests; byte-identical JSON in two processes (Unreleased)
- pins the slice 1a.1 review's rulings: equal values decided exactly (the beta posterior for 100 samples of 1 of 3, a design effect of 1 for equal values in clusters, equal paired differences zero wide); one cluster read as one independent unit with `few_clusters`; valid inputs never raising (an effective size just above 1, the beta posterior and McNemar at the largest counts); no bootstrap over fewer than two clusters; `detectable` null where nothing is detectable; t's quantile within 1e-10 relative of `spec/fixtures/evals/t_quantile_reference.json` at every level and degree of freedom it holds (Unreleased)
- pins the round 2 review's rulings: every interval holds the point it is shown with, in its numbers and its text (the one-sided beta posterior when every trial passed or failed; the beta posterior and the bootstrap moved at their level where the equal-tailed cut leaves the point out); a confidence above 0.999999999 refused at every entry point with one plain message; `detectable` at every baseline strictly between 0 and 1 (Unreleased)

### `spec/smith/evals/statistics_standalone_spec.rb`, `spec/smith/evals/no_ruby_llm_spec.rb` and `spec/smith/evals/rubocop_directives_spec.rb`

Purpose:

- `require "smith/evals/statistics"` alone, in a child process, loads no workflow code and installs no observer; `require "smith"` defines none of slice 1a.1's constants; no file under `lib/smith/evals/`, nor canonical JSON or the scope type, names the provider gem; their RuboCop directives use only `disable` and `enable`, which RuboCop 1.85 reads as 1.92 does (Unreleased)

### `spec/smith/evals/identity_spec.rb`

Purpose:

- pins `Smith::Evals::Identity` against `spec/fixtures/evals/identity_reference.json` (copied from the slice 1a contract examples, which the reference generator computed): all seven example records' eval run ids, their 693 trial ids, the sample ids digest, the plan digests, the code and data suites' versions and measure digests, the variant digests and the group id; each id's frame, the sample ids digest's frame and the plan digest's format field; the infrastructure errors in the suite version and the measure digest; an independent vector for the sample ids digest's UTF-16 order; random ids without a key; refused id parts; ids sorted by UTF-16 code units; the same bytes in child processes under the C and Turkish locales and other time zones (Unreleased)

### `spec/smith/evals/dataset_spec.rb`, `split_rule_spec.rb`, `sample_spec.rb` and `contracts_spec.rb`

Purpose:

- pins datasets: the example dataset rebuilt with its four hashes, version and split (37 dev, 8 holdout, 3 calibration) and its `manifest.json` byte for byte; adding samples moves none; clusters stay together; a hand-set split wins and a straddling cluster is warned of, never written; UTF-16 order; a changed label moves only the labels hash; null hashes as absent; operational fields unhashed; every label kind counted, a disputed one included; a rebuilt manifest the same but for `created_at`, and `previous_version` on change; duplicate ids, an empty set and an unexpiring production-run sample refused; changed samples, a hand-edited manifest and a pinned version refused with the parts named; malformed lines refused by line number, never echoing content; a host source verified the same way, in its scope, its manifest read with String keys; independent vectors for synthetic and source in the metadata hash; shares kept as Floats; a split rule refused on rebuild unless re-split, a re-split recorded in `resplits` and kept, moved samples warned of; every derived count edited by hand refused, unknown fields inside derived objects ignored; a repeated key, a comment or an unknown escape refused whatever the json gem keeps; a line of 4 MiB before CR LF read and one byte more refused; NUL lines and nesting past 64 refused by name; control characters in `samples_file`, links out of the folder, FIFOs and directories refused without blocking; empty lists written `[]` whatever the json version (Unreleased)
- pins the split rule's exact integer thresholds (never Float arithmetic), its framed bucket and its edges; the sample line's every field rule by path, a null inside label or source refused as the schema refuses it; and every published dataset and suite example, and every manifest and sample this slice writes, valid against `docs/evals/schemas` as published and with unknown fields refused (Unreleased)

### `spec/smith/evals/suite_spec.rb`, `score_spec.rb`, `scorer_spec.rb`, `reducers_spec.rb`, `configuration_spec.rb`, `actor_spec.rb`, `errors_spec.rb` and `loading_spec.rb`

Purpose:

- pins suites: the published code suite's manifest and version (`sha256:c23bed10...`), its 37 selected samples and measure digest (`sha256:41f4d145...`), the same in child processes under other locales and time zones; budget and the dataset's location outside the version; a scorer's version, scale, reducers or failure rule changing both digests; a target and the subject's identity in the version only; defaults written out; the infrastructure errors as sorted class names in both digests; keep written sorted; independent vectors for a narrowed selection and for until; class scorers, and version or scale beside a scorer instance refused; narrowing as sorted data; integers past 2**53 - 1 and text not in UTF-8 refused as problem lines; a subject's missing or unknown settings collected as problems; a pin; a host source read in the run's scope; inheritance; every `SuiteInvalid` case of design 4.5 by its problem line, every problem at once; `SplitNotAllowed` for holdout and calibration (Unreleased)
- pins scores (bounds, `score_invalid`, `grader_undecided`, the trial line's fields), scorers (class and block, inherited settings, the other scale or a raise made unscored, naming the error's class only), reducers (names, scale fit, the table's values and the statistics module's agreement), the configuration (defaults, bounds, a frozen copy per run), actors, the errors, and loading: `require "smith/evals"` defines them and installs no observer, `require "smith"` loads none of them (Unreleased)

### `spec/smith/evals/stores/memory_spec.rb`, `spec/smith/evals/stores/file_spec.rb`, `spec/smith/evals/store_spec.rb` and `spec/support/eval_store_examples.rb`

Purpose:

- pins the eval store interface with one example group both stores pass: a header created once (a second create `:exists`, never clobbered) and filed only under its own scope; every record of the contract examples (`spec/fixtures/evals/records`, copied from the slice 1a contracts) read back byte for byte and valid against its schema, open and strict; every field checked on the record as it will be kept, so a Hash whose default answers a read is refused; every JSON value kept exactly and anything JSON cannot hold refused; a number known by its value (1.0 is 1, -0.0 is 0); frozen copies; one lease at a time (`RunBusy`) and writes only under the run's live lease; lines in append order, a read yielding the lines there when it began, an identical line `:exists`, another under a held id refused, 8 MiB at most, none lost to eight threads; a summary only above the stored revision; an idempotent cancel, its time in UTC without changing the clock's Time; listing newest first with a cursor that walks every record once; two scopes apart; ids that could name another path or alias one refused; the twelve methods (an object missing one is no store), the lease and the default store, none when the working folder is gone (Unreleased)
- pins the file store: the `v1` layout, a run's folder byte for byte the published example's; a root that is a link; folders 0700 and files 0600; nothing written before the first write; each record flushed to the drive before it returns (F_FULLFSYNC on macOS, fsync where there is none), its folder when a name is added, every folder from the root down on each create and lease, and a cut's copy before its rename; stray temporaries of its own form swept after an hour by the system clock, on a create or a lease; crashes made real by killing a child process with SIGKILL mid-append, mid-create, mid-replace and mid-cancel, and at random moments, leaving whole records or a torn last line that readers skip and the next lease holder cuts by replacing the file (so a reader already reading never sees a mixed line); a complete line that does not parse `RecordCorrupt` with its number, a line read 8 MiB and a byte at most, a header, summary or flag over 8 MiB refused; a fragment of its own failed write cut, and its ids read again, before the next append; ids read afresh each lease; a run that does not read skipped and named once in a listing walk; a lease freed when its process dies, never written under or held by a forked child, and no descriptor left when one cannot be taken; one create and one lease among racing processes; no line lost by two writing processes; no link followed at any folder or file, and no write to a file with another link; anything but a regular file refused without blocking on a FIFO; a first create that cannot link says why (Unreleased)

### `spec/smith/template_spec.rb`

Purpose:

- pins `Smith::Template`: `{{name}}` and `{{ name }}` fields in order of first appearance; every Mustache form outside the subset (sections, inverted sections, closings, partials, comments, triple braces, unescaped tags, delimiter changes) and every other `{{` refused at its line and column in characters, a run of braces once, at most 100; its reading rules private; values filled in one pass, as they are, Hash and Array values as canonical JSON; UTF-8 out, a Latin-1, UTF-16 or binary String converted and one with no UTF-8 form refused naming only the field; `TemplateValueMissing`, a `WorkflowError` naming only the field; 1 MiB read and filled in under a second, and twice as much in at most three times as long (Unreleased)

### `spec/smith/prompt_spec.rb` and `spec/smith/prompts_spec.rb`

Purpose:

- pins `Smith::Prompt`: a component id under definition format 1's rule, text kept as given and versioned by its SHA-256 as format 1 versions a component, a file read as it is (ERB and Ruby interpolation never run), a replacing text keeping exactly the fill-in fields (one added, removed or renamed refused with `Smith::PromptInvalid`), fields filled in once; `require "smith"` loading none of it until it is named (Unreleased)
- pins the prompt seam on the wire: a named prompt sent as the agent's instructions, filled from its declared inputs, inert (ERB, interpolation and a value's own braces sent as written); a field naming no input, an untrusted key and a missing value each failing the step before any request, the attempt stamped with no version; the default in a direct RubyLLM call; inheritance, replacement by a plain declaration or a later instructions block; a trial's candidate sent and its version on the observation, the usage entry, the `:provider_call` trace and the saved pins; the candidate over the registry's active version, the registry not asked; a restored run under a candidate, and an inline child built under one its parent was built outside, each sending and recording the candidate; a nested candidate merged over the outer one, fiber-local as a trial's attribution (a fiber or thread a host starts inside it never takes it), and out of force after its block, by a raise too; an inline child its run builds after the block keeping it for its own components; Symbol-keyed candidates and handed-down pins; a candidate with other fields refused before anything runs; `Smith::Prompts.components`, and the seam's internals private; a waiting run's pinned text kept when the label moves and after a deploy edits the prompt with no registry, across a restore, the registry not asked; each pinned text saved once, and a saved text that is not its version, a pin without its text or another shape refused; a nested workflow sharing the pins and a child run starting from them and pinning its own further component; parallel branches sending one version from one registry read; fan-out branches, optimizer and orchestrator agents pinned at the start; a run saved before pinned when restored; an agent registered behind a block pinned once at first use, its candidate and the registry honoured in a fresh process; an agent called from Ruby in a compute step or a parallel branch's tool sending the run's candidate or pin, one the definition does not name pinned at first use; a usage entry's components of one shape only from a branch's results and from a saved run, refused with Smith's own errors; an agent class's own components on every record of its attempts, another shape refused; a registry text or a second declaration with other text refused; an agent without a named prompt beside one that has one left as it was (Unreleased)
- `spec/smith/image_agent_spec.rb`: an image agent paints from its named prompt as the run sends it and stamps that version (Unreleased)

### `spec/smith/definitions/format_spec.rb`, `document_spec.rb`, `digests_spec.rb`, `contracts_spec.rb` and `loading_spec.rb`

Purpose:

- pins definition format 1: the design's agent and judge and every reference document accepted; one failing document per rule with its exact "path: problem" lines (the JSON form, the format, a kind this Smith does not read (reserved), closed fields, credential-named keys, ids, inputs and their trust and fence, the llm, its settings checked against Smith's model table, fallbacks, outputs in the portable subset, prompt components and their fill-in fields, numbers, a Float canonical JSON writes as an integer past 2**53 - 1 among them, half a surrogate pair); each credential word; an input with no trust kept out of a system component; every Mustache form refused in a component; each bound at and past its limit (1 MiB of canonical JSON or of text, 32 levels, 20,000 values, 64 KiB and 200 fill-in fields a component, 10 schema levels through references, 100 problems); problem lines that show a long key or value by its first 64 characters, so 100 of them stay under 16 KiB for a document of any size (Unreleased)
- pins the Document API: the document as written, frozen, nothing filled in, no reference kept to the host's Hash; `placeholders`; `replace_component` with the same fill-in fields; `with_llm` keeping the prompt digest and component versions, settings and fallbacks written out, a setting the new model or a host-registered profile does not take refused by name; a stored definition read back with `stored: true` after the model table changed, held to every other rule (the llm's included), saying so with `stored?` while nothing derived from it does, and `stored:` only true or false, while `parse` and `with_llm` refuse it; `with_llm` writing only its four llm fields; `replace_component` taking the same fields in another order; every variant of the published slice 1a model comparison one `with_llm` makes (Unreleased)
- pins the digests against `spec/fixtures/definitions/reference.json`, computed by a Python script with the slice 1a reference canonical JSON: the document, prompt, agent and workflow digests and component versions of six documents, the slice 1a model comparison examples' subject digests among them; the frames; frozen digests; every field but the annotations in each digest, the llm outside the prompt digest; key order, white space, Symbol keys and annotations changing nothing; every reference document read back, fresh and stored, from its canonical JSON, a JSON.stringify copy and Ruby's JSON text to the same digest and bytes; the same bytes in child processes under other locales and time zones (Unreleased)
- pins `docs/schemas/smith-definition-1.json`: valid 2020-12, its examples the design's agent and judge, and they, the reference documents and the documents `with_llm` and `replace_component` write valid as published and strict; each rule Smith keeps that JSON Schema can state refused by the schema too (credential-named keys at any depth, closed objects listing their properties, a lone `$ref`, a type on every node, line breaks in names under Ruby's `^` and `$`, repeated fallbacks, the number range), and each it cannot named in its description; and loading: `require "smith/definitions"` defines the format, its errors and the template, `require "smith"` none of them, the template and the digests load alone, no file names the provider gem, and their RuboCop directives are only `disable` and `enable` (Unreleased)

### `spec/smith/evals/recorder_spec.rb`, `recording_spec.rb`, `drivers/in_process_spec.rb`, `outcomes_spec.rb` and `spec/support/eval_trial_context.rb`

Purpose:

- pins running one trial (slice 1a.4): with trace content off, step records holding each step's system, user and assistant messages and its reply while traces hold none; one step per provider attempt across parallel branches, a fan-out, a nested run, optimize and orchestrate; a fallback recorded failed (transient), a repair as a second step; long texts, tool results and arguments cut and marked, max_steps keeping the first and last, max_step_bytes eliding from the middle, max_trial_bytes dropping later steps' messages, content off keeping failure kinds, tokens and tool call names; Smith's fixed text for a 401, a 402 and a 403; each step priced from its own tokens (by mode, image tokens at their rates; 0 or unknown with none), a run the host drives on the trial's thread costed; offsets increasing for sequential steps by at least the first's duration and overlapping for parallel branches; the settings its request carried (a stubbed request none), an effort kept beside a budget, and a value the schema would refuse (a negative or Rational temperature, an integer past JSON's safe range, a long effort) null with the step kept; each response of an attempt priced alone under a tiered price, as the ledger settles it, completed and failed part way, and a step with one response past a bounded last tier unknown; a memo's replay, a skip and a refusal before the call not counted as provider calls; an invalid UTF-8 text marked cut; an offset never before the recorder's start; a step dropped past max_steps freeing its bytes for the steps kept after it; every step valid against the trial schema's step, open and strict; each attempt reaching only its own trial's recorder; the in-process driver's interface, its kept keys, trusted scope keys written from the eval scope and a conflicting mapping refused (`ScopeConflict`), the mapping's own failures let out, a durable retry ended at once or slept, `until:`, waits, a variant's class, an until run's output from its last step, and an inline launcher's child runs counted and marked `child_runs_not_followed` (only child-run steps, none for a host's launcher that runs them on the trial's thread, and kept when the run raises after them); a run ending as a plain `run!` ends it (state, output, error, kept keys, usage), answered and failed; a failure in building the result the driver's own; a trial's seed from its id and its context's JSON form; `Smith::Evals.under` keeping the attribution a host gave around it; what a scorer reads; and every row of design 6.2 and 6.3 from the real error, in order (interrupting errors, a host's infrastructure errors in the causes, credential classes and a scrubbed error by class, wrappers by their cause, a WorkflowError subclass raised inside a rescue as itself, then each family), provider_unavailable from the last failed attempt, the provider rows from the kinds the seam recorded on a real 401, 402, 403, 404, 400 and 529 (Unreleased)

### `spec/smith/optimize_batch_spec.rb`

Purpose:

- pins batch mode on an `optimize` step: each call of its loop a batch request of its own, the run waiting between calls and going on from the loop's progress (Unreleased)

Architecture basis:

- Agents (docs/AGENTS.md): Batch mode; Persistence (docs/PERSISTENCE.md): waits, restore

Documented contracts covered:

- `optimize` takes `mode:` and `on_request_change:`, needs `on_failure` to batch, shows its mode in graph inspection, and runtime readiness reports a generator or evaluator that cannot batch
- in lax and strict modes, through every shipped store adapter, each call waits in turn (generator, then evaluator, round by round), each delivery goes on from the stored progress, and each call's usage is recorded once with `mode: :batch` and its round
- the progress kept with each wait (round, call, candidate, feedback, what `before_generate` told the round, verdicts), so a delivered round's request is the one sent; `before_generate` and `before_eval` run once a round and callables read every verdict so far across waits; the mode callable is asked at each call and a `:sync` call goes over the wire
- a missing result fails its call, and an in-process `retry_on` runs the loop afresh under the new attempt's mode; an errored result fails through `on_failure`; a delivery that crashes keeps the stored wait, and a second delivery goes on as the first would have
- a call whose request changed is resent over the wire under `:resend`, its batch result charged; progress past `persistence_max_bytes` fails the step before anything is queued
- run budgets charge each result once; a host ledger holds each call's request under its custom_id and settles it with its result before the next call is held, so a ledger with room for one hold takes the next
- in strict mode a crashed delivery leaves the run stored as a step under way (`StepInProgressOnRestore`), as on any batch step
- restore refuses missing, malformed or out-of-range progress, progress that is not the progress of the call its wait was made for, and progress on another kind of batch step

### `spec/smith/workflow/optimize_before_generate_spec.rb`

Purpose:

- pins `optimize ..., before_generate:` and the round a capture names, so a host can set aside what a rejected round or a failed attempt staged (Unreleased)

Architecture basis:

- Evaluator-Optimizer (docs/PATTERNS.md); Tool Result Capture (docs/TOOLS_AND_GUARDRAILS.md)

Documented contracts covered:

- `before_generate` runs before each round's generator with the live context and `state.round`, so a host's staged work from a rejected round is gone before the next round writes
- `{ rejected_round: String }` from `before_generate` is told to a later round's generator after the feedback (`[smith:rejected-round]`); a bare String, blank words or anything else tells it nothing, and a `rejected_round` that is not a String fails the step
- it runs again before an in-process retry's first round, after the failed attempt's tools ran, and only that attempt's captures remain
- a raise fails the step before the round's generator is asked; a non-callable is refused when the workflow loads
- each capture an optimize round takes names its round, concurrent tool calls' included; a provider attempt set aside inside a round takes its captures with it, the kept ones naming the round; the round survives a persisted run's restore; a capture outside an optimize round has none

### `spec/smith/workflow/from_nil_failure_spec.rb`

Purpose:

- pins that a failure in a step declared `from: nil` is stored, restored and routed by `on_failure` as any other step's (Unreleased)

Architecture basis:

- Persistence and durability (docs/PERSISTENCE.md): restore, durable retry, renames

Documented contracts covered:

- in lax and strict modes and through every shipped store adapter (Memory, ActiveRecordStore, RedisStore, CacheStore, RailsCache), the failure of a deterministic or an agent step is stored with `from: nil`, the run restored one step at a time takes its `on_failure` route, and a run that ended failed there reads back `last_error` and `failure_detail` as the run that made them did
- the class-level `run_persisted!`, `restore_or_initialize`, `restorable_billing_state?`, a durable retry's expired wait and a later version's renames (of the failed step itself too, read back through the run's result) all go through such a stored run
- a record as 0.13.0 stored it restores; an origin that is not a state name (a number, blank, over 256 bytes), a record without `from`, and a nil `transition` or `to` are still refused

### `spec/smith/tools/declaration_inheritance_spec.rb`

Purpose:

- pins that a `Smith::Tool` subclass inherits every declaration of its parent's, each overridable, and that `authorize` is never lost on a subclass (0.13.0)

Architecture basis:

- Tools and guardrails (docs/TOOLS_AND_GUARDRAILS.md): Subclasses

Documented contracts covered:

- `description` (and `desc`), `with_params`, `category`, `authorize` and `before_execute` are the nearest declared up the chain, a grandchild's included, and a subclass's own replaces its parent's without changing the parent
- `param`s add up by name (a subclass adds or replaces one); a `params` schema is the nearest, unless the subclass declares `param`s of its own; the parent's schema is unchanged
- a declaration made on the parent after the subclass was created reaches the subclass, `compatible_with` included (spec/smith/tool/compatibility_spec.rb)
- a grandchild's `param`s do not bring back parameters a class between replaced with a `params` schema
- a host subclass of a shipped stub (`Tools::WebSearch`) keeps its description, parameters and compatibility
- `capabilities` merge key by key, `replay` aside (never inherited): an inherited `privilege :elevated` denies the subclass, an inherited `sensitivity :high` strips its tool-call traces' content, and a subclass's own key (`privilege :none`) replaces only that key
- an inherited `authorize` denies a subclass and a grandchild as it denies the parent; a subclass's own replaces it (and can call `superclass.authorize`); a tool none of whose classes declares one runs as before

### `spec/smith/tools/replay_safe_spec.rb`

Purpose:

- pins that a tool declaring `capabilities { replay :safe }` leaves its step the follow-ups, fallbacks and retries a tool that ran would otherwise forbid, and that every other tool keeps the step as before (0.13.0)

Architecture basis:

- Tools and guardrails (docs/TOOLS_AND_GUARDRAILS.md): Replay-Safe Tools
- Errors and retries (docs/ERRORS_AND_RETRIES.md): After tools ran, the response memo
- Agent outputs (docs/AGENTS.md); durable retry (docs/PERSISTENCE.md)

Documented contracts covered:

- `replay :safe` and `replay :unsafe` are the only values, unsafe is the default, and `replay_safe?` reads it; it is never inherited: a subclass (or grandchild) of a replay-safe tool is unsafe until it declares `replay :safe` itself, while keeping its parent's other capabilities, and a step using such an undeclared subclass stays uncertain (no fallback) until it declares
- after replay-safe tools only, an output repair, a refusal fallback and a truncation retry are made, each a new call from the step's messages whose tool loop runs again; a repair carries no tool messages of the set-aside attempt
- after replay-safe tools only, a provider failure takes the fallback model, the step's failure is its own error, retried in process and durably (the stored waiting run holds no captures of the failed attempt), and the next attempt runs the tools again
- a set-aside or retried attempt's captures leave `tool_results`, by identity: a concurrent fan-out branch's equal captures, made between them, stay; a tool loop paused for budget keeps its captures for the retry that continues it
- captures leave only once they are replaced: a repair that fails at the provider, a fallback model that fails too, and a durable retry whose wait cannot be entered (past the persistence TTL) all leave the failed step with every capture
- a budget refusal carrying a paused loop that is not the run's own (raised by a nested workflow or by host code) is uncertain after an unsafe tool, so the parent does not start the child over
- once a tool that is not replay-safe ran (in one round with a safe one, or before one), the step is uncertain as before: no follow-up, no fallback, no retry wait, `ToolOutcomeUncertain`, its captures kept
- a nested workflow's tool evidence reaches the parent step as it was: safe tools leave the parent's retry, an unsafe one makes it `ToolOutcomeUncertain`
- a call the response memo replays after a crash counts its kept tool results by the tools its chat declares: all safe takes the fallback (the tools run again), one unsafe stays uncertain
- the review fixes are mutation-verified against the full suite (12 mutants: 10 killed; 2 survive on unreachable states, a kept tool result answering no call, which record validation refuses, and an attempt without a start mark)

### `spec/smith/provider_errors_spec.rb`

Purpose:

- pins that an error of a streamed request is what the provider said it was, whatever status RubyLLM guessed (0.12.6)

Architecture basis:

- Provider failures and fallbacks; streaming

Documented contracts covered:

- a streamed bad request fails its step, sent nowhere else
- OpenAI's streamed wrong key is the account's, so the next provider answers
- each type Anthropic or OpenAI names is the error RubyLLM raises for its status, context length included, with the provider's message and the response's headers, the guessed error its cause
- a type said without a message takes RubyLLM's words for its status
- an error whose guess was right, whose body names nothing known, or that the provider sent whole stays as it is
- every entry of the type table and every guard is mutation-verified

### `spec/smith/streamed_requests_spec.rb`

Purpose:

- pins that a streamed step's requests are each sent once, without RubyLLM's HTTP retries (0.12.5)

Architecture basis:

- Streaming; provider failures and fallbacks

Documented contracts covered:

- a streamed refusal for want of credit is a `RubyLLM::PaymentRequiredError` with RubyLLM's retries on, sent once
- a stream that fails part way is not sent again, though a good reply waits, and its text is not streamed twice
- a call that does not stream keeps RubyLLM's retries, and so does a request OpenAI's Responses route sends whole
- a streamed call keeps the agent's own config (its context), and neither it nor RubyLLM's global config is changed
- a model RubyLLM lists keeps its output limit and thinking budget when it streams
- these contracts are mutation-verified

### `spec/smith/cache_markers_spec.rb`

Purpose:

- pins that a prompt-cache marker never changes what identifies a request (0.12.3)

Architecture basis:

- Section 5, Persistence and Resume

Documented contracts covered:

- Anthropic's `cache_control` markers are left out where they sit (the request, its system and message blocks, a tool result's blocks, its tools); a tool's input or schema, however marker-shaped or deeply nested, is never touched
- a replay whose call caches its instructions, or its whole request, where the first call did not finds the response memo's answer and sends nothing; two calls whose tool inputs differ keep different keys; a call whose instructions changed is sent again
- a batch request is the same request with or without cache markers, and another once what it asks changes (a tool schema included); a digest Smith 0.12.2 took with its markers still matches the request as it was
- a seed whose content parts are now cached, or no longer, passes `seed_validation :strict`; a seed digest Smith 0.12.2 took with its cache flags still matches the seed as it was
### `spec/smith/budget_ledger_spec.rb`

Purpose:

- asserts that a workflow's `budget_ledger` holds each provider request a step makes before it is sent and settles it with what the request spent

Architecture basis:

- Section 6, Budgets; Section 5, Persistence and Resume; Section 7, Observability

Documented contracts covered:

- the block is called at the run's first request with its scope: the named keys' values in its trusted context when it was created (an untrusted key or a non-scalar value refused), kept with the run as `budget_ledger_scope` and unchanged by what a step writes later; a malformed stored scope raises `SerializationError`; restoring a run or ending its wait never builds the ledger; nil means none; an object without `reserve!`, `reconcile!` and `release!` fails the step
- a request is held under `"<attempt_id>:<round>"` (the `:provider_call` trace's attempt id) with its output cap and an estimate of its input, priced from the catalog, until `budget_hold_ttl` from now, and reconciled with its priced usage; a streamed request reconciles the usage its stream reported
- a refusal (anything but `true`) raises `BudgetUnavailable` (a `BudgetExceeded`, restored as one) before anything is sent; an error from `reserve!` raises `BudgetLedgerError`, releases the key, sends nothing and tries no fallback; an error from `reconcile!` is logged by class only and the answer is kept
- a call's first request is held and every round of its tool loop reconciled under its own round; a request that failed without usage is released before a fallback model's, which has its own attempt id
- a nested workflow without its own ledger charges the enclosing run's; each sync fan-out branch is held from its own thread; a tool's own RubyLLM call is not held
- a request's cache reads and writes reconcile as input
- a request that marks a block for the prompt cache is held with its input at the dearer of plain input and a cache write; an unmarked one, or a model with no cache-write rate, as plain input
- a batch refusal releases the sibling holds already taken before a retry's backoff
- a batch request is held at capture under its `custom_id`, at the batch discount, until its 25-hour wait plus `budget_hold_ttl`; delivery reconciles a succeeded result and releases an errored one; a refusal queues nothing; an expired wait releases its holds; a step that fails before queuing releases the holds it took
- readiness warns of an agent whose model has no price only when the workflow declares a ledger; `budget_hold_ttl` must be a positive Integer
- the hold estimate counts text at 3 bytes a token, an image at 1,600 and each message's framing at 8, is capped at the context window, and reads the output cap from `max_tokens`, a provider's own name for it, the model, or 4,096, at most `budget_hold_output_tokens` when set
- these contracts are mutation-verified against the full suite

### `spec/smith/budget_ledger_review_spec.rb`

Purpose:

- pins what two reviews of budget ledgers found

Architecture basis:

- Section 6, Budgets; Section 5, Persistence and Resume

Documented contracts covered:

- a request OpenAI's Responses route sends is held once, and refused before it is sent; a plain OpenAI request, through both hooked classes, is held once
- a run's ledger is built once for all its fan-out branches; a step whose `retry_on` names other errors holds no later round of its tool loop
- a batch result is priced under the id RubyLLM resolves the agent's model to, as its hold and its usage are, and readiness checks that id
- an inline child run never charges its parent's ledger
- a batch hold is settled on the ledger it was taken on, whatever a step writes to the context
- a request the queue took before it failed keeps its hold; only the rest are released
- a reply without usage, and a stream that failed after it began, reconcile at the hold; a negative count reconciles as 0
- readiness warns of unpriced optimizer, orchestrator and nested agents, and of a child run whose class declares no ledger (only when the parent declares one), and its metrics name the scope keys
- an image or a PDF in raw content (base64 data or a data URL) counts as an attachment, a PDF by its pages
- a batch capture without a ledger computes no hold
- these contracts are mutation-verified against the full suite

### `spec/smith/budget_pause_spec.rb`

Purpose:

- asserts that a tool loop paused for budget continues from its tools' results, running none of them again

Architecture basis:

- Section 6, Budgets; Section 4.2, Workflows; Section 5, Persistence and Resume

Documented contracts covered:

- a step whose durable `retry_on` names `BudgetUnavailable` holds its loop's later rounds; a refused one waits with the loop's messages in `pending_retry`, and once the host ends the wait the retry continues the loop from them: the tool ran once, the resumed request carries its result, and the paid rounds are counted once
- an in-process retry continues the loop after its backoff; the last attempt's later rounds are not held
- a stored continuation not of the shape Smith keeps raises `SerializationError` on restore
- a loop too large to keep goes on unheld from its tools' results
- these contracts are mutation-verified against the full suite

### `spec/smith/testing_spec.rb`

Purpose:

- asserts the testing kit (`smith/testing`): stubbed agents answered at the wire, runs driven through their waits, and the Minitest and RSpec checks
- a stub answering by request (`outputs:` a callable given a `Smith::Testing::Request`): its agent, number, round, model, system text, messages, last user text, tools and schema; a tool round answered from its round and result; a request's round counted from its last user message past earlier turns; `Smith::Testing.reply` for one request's usage and stop reason, in a list too; an answer it cannot send failing the call and naming the stub; parallel branches answered at once from one callable; `calls` still recorded (Unreleased, slice 1a.4)

Architecture basis:

- Section 4, Workflow execution; Section 5, Persistence and Resume; Section 6, Budgets

Documented contracts covered:

- a stubbed agent's requests send nothing and record the stub's usage, stop reason and message id; a `max_tokens` stop fails the step as truncated; each request's messages are kept
- outputs are taken in turn, the last again; a reply under an output schema is parsed from text or a Hash; an output check's repair takes the next output
- a tool request runs the agent's own tool before its next request; one naming a tool the agent lacks fails the call with the agent's tool names
- stubbed requests are held on the step's budget ledger and kept in the response memo; a tool loop refused at its later round pauses and continues from its tool results
- a streamed step's sink gets the reply in pieces of the stub's size (any size), with usage mode `:stream`; OpenAI's Responses route is answered after its request is rendered
- `unstubbed = :refuse` fails an agent's call that has no stub with `UnstubbedCall`, sending nothing
- `run_until_waiting`, `resume_with` and `expire` run a wait through; a durable retry's backoff ends at once unless `retries: false`
- transitions are those the run completed: a timed-out await is not one; a prepared split step's is recorded
- a batch step's request is still captured; `batch_payload` and `batch_result` deliver an agent step's or a fan-out's results, symbol-keyed ones too
- the checks' failure messages; the Minitest assertions call `assert` and drop the stubs after each test; `reset!` sends a call over the wire again; an unusable stub is refused

### `spec/smith/persistence_max_bytes_spec.rb`

Purpose:

- asserts `Smith.config.persistence_max_bytes`, a stored state's bound

Architecture basis:

- Section 5, Persistence and Resume; Section 6, Budgets

Documented contracts covered:

- the setting is nil or a positive Integer
- a stored run's step whose result would not fit fails with `PersistedStateTooLarge` before the result is kept, in lax and strict mode: its usage is recorded, `on_failure` is taken, the run is stored and restores, and the error restores as itself; a run never stored is not checked
- any other state past the bound raises `PersistedStateTooLarge` (key, bytes, limit) before writing; the stored state stays as it was
- a tool loop refused for budget does not pause into a state the bound would refuse; it goes on unheld

### `spec/smith/doctor/checks/state_model_spec.rb`

Purpose:

- asserts the doctor's default check of an Active Record state model

Architecture basis:

- Section 5, Persistence and Resume

Documented contracts covered:

- a model with a `lock_version`, a text payload and a unique string key passes, in the default run; another locking column, a key without a unique index, a key that is not a string, or one narrower than 64 characters fails with the reason
- the check skips when the database cannot be reached; an encrypted payload passes with a warning, and `replace_exact` refuses it
- other adapters, and an adapter configuration that does not resolve, are not checked
- the durability probe writes with `store_versioned`, as runs do, and leaves no probe row

### `spec/smith/batch_request_change_spec.rb`

Purpose:

- asserts what a batch result does when its step renders another request by the time it comes (`on_request_change:`)

Architecture basis:

- Section 4.2, Workflows; Section 6, Budgets

Documented contracts covered:

- `:resend` sends the request as rendered now over the wire and its reply is the output; the result set aside is charged as a `:failed_attempt` with `mode: :batch`; an unchanged request's result is taken, sending nothing
- `:fail` fails the step with `BatchRequestChanged` (the result charged), which `retry_on` with a mode callable sends again synchronously
- a fan-out resends only the branch whose request changed
- `on_request_change:` takes :keep, :resend or :fail, only on a step that may batch, stays out of `agent_opts`, and shows in graph snapshots
- these contracts are mutation-verified against the full suite

### `spec/smith/batch_review_spec.rb`

Purpose:

- pins what two reviews of batch mode found: paid results never dropped, queued only once an attempt ends cleanly, deliveries checked and bounded

Architecture basis:

- Section 5, Persistence and Resume; Section 6, Budgets; Section 7, Observability

Documented contracts covered:

- a succeeded result no call took (a fan-out branch cancelled by a sibling's failure, or a step that failed before its call) is recorded as a `:failed_attempt` with `mode: :batch` and charged to the budget, and an errored one is not; a later attempt never takes an earlier attempt's result, and its calls are held to the budget
- a step that fails after capturing (its context checks) queues nothing and keeps no wait or pending batch
- in strict mode a completion is stored as a step under way before it runs, and a run caught in one is refused as unfinished
- a batch step in an in-process child fails before anything is captured or queued
- a call that renders another request than the one sent (its payload or its headers) takes the result all the same, its `:provider_call` trace saying `request_changed: true` (and only then)
- a step's failed attempts never outlive it on a thread whose list its thread context puts back
- a succeeded message not of the provider's reply shape (content blocks, text, non-negative usage counts), or a payload nested too deep, raises ArgumentError and keeps the wait; an error type is bounded
- restore refuses a pending batch whose attempt or key generation its step's retry policy does not allow, whose ids are not its branches', or whose digests are malformed, and a fan-out whose branches were renamed
- a mode callable object (not a Proc) is asked with its own arity; a model or tools given by a block is a readiness warning; a batch queue without `enqueue` is refused when set
- a request's own credential headers are refused, and on submit the connection's headers win over a request's
- these contracts are mutation-verified against the full suite

### `spec/smith/workflow/durable_retry_spec.rb`

Purpose:

- asserts that `retry_on ..., durable: true` waits out each backoff as a wait of the run and resumes at the recorded attempt and key generation

Architecture basis:

- Section 4.2, Workflows
- Section 5, Persistence and Resume

Documented contracts covered:

- `durable:` takes true or false, needs `on_failure`, and is refused on await, delay, parallel and fan_out steps; graph inspection and the transition contract show `durable: true`
- a retried failure enters a `:retry` wait (no event or `into:`, due after the backoff) without sleeping, counting a step or completing it, and stores `pending_retry`; a waiting run does not advance; `expire_wait!` before the deadline is `:not_due`, with a stale token `:stale`, and `resume!` never completes it; past the deadline the wait ends with the transition next, and continuing the run makes the next attempt under the same key, then clears `pending_retry`
- the last attempt fails for good through `on_failure`; a settled failure moves the attempts after it to new keys across durable waits, as in-process
- an unpersisted run waits in memory and continues after `expire_wait!`
- a crash during the retried attempt makes the same attempt again under the same key (lax); in strict mode the restore raises `StepInProgressOnRestore`
- no retry wait past the wall-clock deadline, after a tool ran, or for a backoff longer than the persistence TTL; an in-process nested workflow with a durable retry fails the parent's step and readiness reports `:nested_workflow_waits`; split-step persistence refuses the step
- restore refuses a `pending_retry` that is malformed, out of the policy's bounds, names another transition, or is missing beside a retry wait, a due retry without its next transition, and a retry wait, or a due retry, whose transition no longer declares a durable retry
- review fixes: a step that raises or is routed to `:fail` after a retry wait clears its pending retry, so the run restores; one instance waits and expires twice (the claim is released), refreshing `updated_at`; `:retrying` traces carry the attempt, error and deadline and `:retry_due` the run's key; `awaiting.attempt` and `awaiting.error`; a nested child's retried error is the parent's cause; `durable:` needs 2 attempts and a positive backoff; a stored retry wait outside its transition's state, and a definition that drops the durable retry or lowers attempts, raise `UnknownTransitionOnRestore`; a wait as long as the TTL is refused; readiness reports a backoff reaching the TTL (`:durable_retry_outlasts_ttl`) and a durable child run inline; durable agent steps, nesting steps and from-less steps reached through `on_failure` retry; a non-durable policy's graph contract is pinned; a run stopped before the retried step starts (a budget check) keeps its pending retry; a durable retry cannot wait inside split-step execution
- these contracts are mutation-verified against the full suite

### `spec/smith/workflow/wait_spec.rb`

Purpose:

- asserts that `await` and `delay` steps wait durably and boundedly, and that `resume!` and `expire_wait!` complete them exactly once

Architecture basis:

- Section 5.3, State Serialization
- Section 4.6, Budgets and Cost

Documented contracts covered:

- the DSL requires a Symbol `into:`, a positive timeout or callable, and a timeout route (`on_timeout` or `on_failure`) on every await; `on_timeout` only on an await; one execution body per transition
- entering a wait stops the run without counting a step or touching `max_transitions`, stores the wait (with the event and key as declared), makes the run non-terminal with the await as its pending transition, runs the block again under the same token after a crash in it, finishes at once when the block resolves (copying the payload), computes a callable timeout from the context, refuses a non-positive one, checks `into:` against the persist list and the wait against the store's TTL before the block runs, stores the wait `advance_persisted!` entered, and traces entry and timeout
- the token is the step's position under a segment only waits use, so no idempotency key equals it
- `resume!` writes the normalized payload to `into:`, completes the step (StepCompleted, one step counted, the session untouched) and lets the run continue; it is `:stale` and changes nothing for another event or token or a run that is not waiting, `:missing` for no stored run, and `:failed` when the completion takes the failure path; it refuses a payload that is not JSON-shaped and keeps the run waiting; a racing store fails the version check; one completion at a time claims a wait on an instance
- a delivery that arrives before its wait is stored completes the await at once in lax and strict modes, and the process still entering the wait loses its store; any other delivery to a strict run caught mid-step raises `StepInProgressOnRestore`
- `expire_wait!` is `:not_due` before the deadline and `:stale` for another token; past it, an await takes `on_timeout` (emitting StepCompleted that ends in the await's own state), or `on_failure` with `Smith::WaitTimedOut`, which restores as itself with its details; it refuses a `now:` that is not a time; an `on_timeout` route that does not start from the await's state fails the step; a delay continues to its `to:` and is never resumed by an event
- a wait round-trips and restores in strict mode as a checkpoint; a malformed wait, a pending transition beside it, a deadline before entry or without a zone, or negative `active_seconds` raises `SerializationError`; a wait on an undeclared transition, one of another kind, event or key, or one that does not start from the run's state raises `UnknownTransitionOnRestore`; the stored wait cannot be changed through `awaiting` or `to_state`
- time spent waiting does not count toward `wall_clock`; a step that raised or died is charged on restore the time since it began, at most what is left of the budget; a finished run carries no step mark
- a waiting run in a state with no transitions out is neither terminal nor cleared; `stuck_for?` reports a waiting run as stuck only past its deadline plus the threshold; `resume!` and `expire_wait!` refuse an adapter without `store_versioned`
- an in-process nested workflow that reaches a wait fails its parent's step, and runtime readiness reports it; split-step persistence refuses an await step and any step while the run waits; a TTL shorter than the wait is refused on entry
- graph inspection shows the wait and its timeout route, reaches the timeout target, and validation reports an unresolved `on_timeout`

### `spec/smith/workflow/idempotency_key_spec.rb`

Purpose:

- asserts that steps and tools get idempotency keys that are the same on every replay of a request and unique to the run, the step's position, the tool and the scope

Architecture basis:

- Section 5.3, State Serialization
- Section 4.5, Tools

Documented contracts covered:

- a compute step's key is 64 lowercase hex characters, the same on every `retry_on` attempt, different for another scope, another step, and a transition that runs again later in the run; `step.attempt` counts attempts from 1; a first attempt's key does not depend on whether the step declares `retry_on`
- a run restored after a crash mid-step, including in a fresh run's first step, gets the step's earlier keys; a new run gets new keys, even under a persistence key an earlier run used; a run's namespace is assigned at construction; a payload without one gets the same derived UUID on every restore, persisted before the step that uses it; a stored namespace that is not a UUID raises `Smith::SerializationError`
- a later attempt moves to a new key only after this step's own `fail!(..., new_idempotency_key: true)` or an error named in `retry_on ... new_idempotency_key_on:`, and keeps the new key across a later timeout; a nested workflow's step raising the flag does not move the parent's retry; `fail!` refuses a non-boolean flag
- a nested workflow's steps are placed under the parent's step; a workflow advanced inside another's step is a run of its own and leaves the outer step's position intact; parallel branches, fan-out branches, optimizer rounds and roles, orchestrator rounds, and worker tasks named by their content (the same key when a replay reorders tasks, distinct keys for equal tasks and for a task repeated in a later round), and durable composite branches (the same on a worker's re-run) each get their own key; a durable composite preparation's guardrails get the step's position; event handlers and `on_step` callbacks get none; no position leaks out of a run
- a tool's key is carried into concurrent tool calls, differs per scope and per tool, differs from the step's key, is refused outside a step and for a tool without a name
- scopes hash alike whatever their Hash order or Symbol and String spelling, convert other encodings to UTF-8, count a whole Float as its Integer, and refuse NaN, Infinity, Rationals, other objects, invalid Strings, duplicate or non-String keys, cycles, nesting past 32 levels and more than 100,000 values; position segments take only Strings, Symbols and Integers, as frozen copies
- `retry_on new_idempotency_key_on:` shows in graph inspection (snapshot and transition contract) only when declared and leaves `retry_config`'s shape alone otherwise; it refuses classes the policy does not retry, a class listed twice, non-classes, retry-forbidden classes, and nested workflow, parallel, fan-out, optimize and orchestrate transitions in either declaration order; it accepts subclasses of retried classes and any class when Smith's classification decides retries

### `spec/smith/workflow/restore_position_spec.rb`

Purpose:

- asserts that a persisted payload naming a state or pending transition the workflow class no longer knows is refused at restore instead of restoring as a silently terminal run

Architecture basis:

- Section 5.3, State Serialization

Documented contracts covered:

- a state named only by a transition's `from:` or `to:` restores and resumes
- an unknown state raises `Smith::UnknownStateOnRestore` with `workflow`, `persistence_key` and `state`; a payload with no state is refused when the class has an initial state; String-named states restore as the Strings the class declares, mid-run and terminal; states named only by `from:` or only by `to:` are known; the persistence key in the message is bounded and the message advises a schema-version bump; a stored run in an unknown state reports as stuck through `stuck_for?` (all mutation-verified against the full suite)
- an unknown pending transition raises `Smith::UnknownTransitionOnRestore`; a declared one restores
- `migrate_from` runs before the check, so a migration can map an old state name to a new one; a `migrate_from` without a schema-version bump does not run and the payload is still refused; a `definition_digest` mismatch is reported before an unknown state (mutation-verified)
- both refusals are `Smith::Error`s, not `WorkflowError`s, and neither retryable nor retry-forbidden (mutation-verified)

### `spec/smith/workflow/persistence_ttl_spec.rb`

Purpose:

- pins the per-workflow `persistence_ttl` DSL contract: workflow classes override `Smith.config.persistence_ttl`; `Workflow#persist!` resolves class DSL > global config > nil and forwards `ttl:` to adapters only when non-nil (bare-adapter backward compatibility)

Architecture basis:

- Section 5.3, State Serialization (TTL on persisted state)

Documented contracts covered:

- `Workflow.persistence_ttl` defaults to nil; accepts positive Integer or Float; rejects 0, negative, non-Numeric
- class-level DSL propagates through inheritance; child class can override parent
- `Workflow#persist!` forwards class-level TTL to versioned adapter (`store_versioned(..., ttl:)`)
- `Workflow#persist!` forwards class-level TTL to non-versioned adapter (`store(..., ttl:)`)
- falls back to `Smith.config.persistence_ttl` when class DSL is nil
- class-level DSL wins over `Smith.config.persistence_ttl` when both set
- omits the `ttl:` kwarg entirely when both are nil (empty-Hash splat `**{}` is a Ruby no-op)
- bare external adapters with `store(key, payload)` (no `ttl:` kwarg, no `**kwargs`) keep working when TTL is nil; they only break if a host opts into TTL with an incompatible adapter
- TTL is resolved fresh on each `persist!` (host can mutate config between persists)
- end-to-end with Memory adapter: per-workflow TTL expires entries; global config TTL also expires when class DSL is unset

### `spec/smith/workflow/run_result_spec.rb`

Purpose:

- asserts the documented `run!` result surface and max-transition failure behavior

Architecture basis:

- Section 5.2, Workflow Execution
- Section 5.6, Error Hierarchy

Documented contracts covered:

- `run!` result responds to:
  - `state`
  - `output`
  - `steps`
  - `total_cost`
  - `total_tokens`
  - `context`
  - `session_messages`
  - `usage_entries`
  - `terminal_output`
  - `last_error`
  - `failed_transition`
  - `failure_detail`
  - `done?`
  - `failed?`
- `total_cost` is Smith's best-known computed workflow cost subtotal
- `total_tokens` is Smith's best-known workflow token subtotal
- `context`, `session_messages`, `tool_results`, and `outcome` expose final workflow state snapshots for host handling code
- `context`, `session_messages`, `tool_results`, and `outcome` are deep snapshots, so host mutation does not leak back into workflow internals
- `usage_entries` exposes the per-agent-call billing facts list (one `Workflow::UsageEntry` per agent provider call: `usage_id`, `agent_name`, `model`, `input_tokens`, `output_tokens`, `cost`, `attempt_kind` ∈ `{:completed_attempt, :failed_attempt}`, `recorded_at`) — deep-copied on RunResult population so host mutation does not leak back into `@usage_entries`
- `usage_entries` populated by completed agent attempts AND by failed-but-billable fallback attempts (the latter when the provider call returned token usage before failing)
- `last_error` and `failure_detail` synthesize from the persisted `@last_failed_step` snapshot when steps is empty on terminal-restore (preserves classification + retryable flag + kind/details for `Smith::DeterministicStepFailure` / `Smith::ToolGuardrailFailed` across persist→restore→retry)
- `output` falls back to the persisted `@last_output` only on terminal-restore with empty steps (a fresh-run workflow that produced nil output is NOT shadowed by stale `@last_output`)
- `failed_transition` and `failure_detail` expose convenience access to the last failed step
- known pricing plus known usage contribute non-zero computed cost to `total_cost`
- multiple successful agent calls aggregate their known computed costs into `total_cost`
- stepwise execution via `advance!` followed by `run!` preserves cumulative `total_cost` and `total_tokens`
- persisted resume via `.from_state` preserves cumulative `total_cost` and `total_tokens`
- repeated `run!` on an already-terminal workflow leaves cumulative totals stable
- missing pricing does not fabricate cost
- malformed pricing entries do not fabricate cost or fail execution
- missing usage metadata does not fabricate cost
- known computed cost reconciles against the `total_cost` budget dimension
- `Smith::MaxTransitionsExceeded`
- workflow remains in its current state when max transitions are exceeded
- `run!` returns immediately when already terminal
- `run!` advances until `terminal?` becomes true
- wildcard `:fail` is not treated as a normal next step
- `on_success` selects the named next transition when multiple transitions share a state

Notes:

- This spec checks the documented result interface and exception behavior.
- It now also covers two workflow-control semantics:
  - failure-only wildcard `:fail`
  - runtime use of `on_success`
- It now also covers real last-step output from workflow agent execution and runtime `output_schema` application.
- It now also covers `data_volume`-driven workflow output shaping:
  - bounded outputs may remain inline
  - unbounded outputs may pass with artifact-ref handoff plus lightweight scalar fields
  - invalid unbounded output shapes route through `on_failure` at the workflow boundary
- It now also covers best-known execution cost behavior:
  - `total_cost` aggregates known model-call cost only when pricing and usage are both trustworthy
  - unknown pricing or unknown usage leaves cost optimistic/partial instead of fabricated
- It now also covers cumulative total stability across:
  - uninterrupted runs
  - stepwise execution followed by `run!`
  - persisted resume
  - repeated `run!` on an already-terminal workflow
- It now also covers best-effort `total_cost` budget reconciliation when computed cost is known.
- It does not yet assert the full content of `steps` entries.

### `spec/smith/workflow/usage_tracking_spec.rb`

Purpose:

- asserts the durable shape of per-agent-call billing facts and the terminal-restore-correctness fields on `Workflow` state, plus the two host-facing peek APIs that hosts use to drive billing-aware credit guards

Architecture basis:

- Section 4.2, Workflow
- Section 5.3, State Serialization
- Section 4.8, Observability (cost tracking)

Documented contracts covered:

- `Workflow::UsageEntry` struct shape (8 fields: `usage_id`, `agent_name`, `model`, `input_tokens`, `output_tokens`, `cost`, `attempt_kind`, `recorded_at`)
- `UsageEntry#to_h` round-trips through `UsageEntry.from_h` preserving every field
- `UsageEntry.from_h` coerces stringified `agent_name` and `attempt_kind` back to symbols (host JSON round-trip safety)
- `RunResult.new(...)` accepts keyword arguments (regression: plain Struct without `keyword_init: true` would route the kwarg hash into the first positional field — `state` — and leave everything else nil)
- fresh-run RunResult exposes `usage_entries` as part of the documented surface (defaults to `[]` for a no-agent workflow)
- persisted state predating this slice (no `usage_entries` key) restores `@usage_entries = []` without raising — backward compatibility for in-flight workflows persisted before the slice
- `@usage_mutex = Mutex.new` is eagerly initialized on `restore_state` (load-bearing — `Workflow.from_state` uses `allocate` and bypasses `initialize`; without the eager mirror a restored non-terminal workflow would `NoMethodError on nil:NilClass` when usage recording runs)
- `@last_output` survives a `true`-string value through to_state / from_state
- `@last_output` preserves a `false` value (regression: `||`-based restore would drop `false`; key-presence check restores it)
- terminal-failed restore synthesizes `RunResult#last_error` from `@last_failed_step` and preserves `Smith::DeterministicStepFailure#retryable` / `#kind` (with `error_details` JSON-normalized — Hash keys + symbol values become strings)
- custom `Smith::DeterministicStepFailure` subclass with a non-message constructor reconstructs as the parent `DeterministicStepFailure` via the `RETRYABLE_BEARING_FAMILIES` family fallback (preserves retryable + kind even when `const_get` cannot construct the subclass with the snapshot kwargs)
- `error_class` that cannot be resolved (`NameError`) falls back via `error_family` (e.g., `agent_error` → `Smith::AgentError.new(message)`) so host error-family classification round-trips
- malformed record shape, class/family metadata, retry policy, failure kind, and known typed failure details are rejected during `from_state` as retry-forbidden `Smith::PersistedFailureInvalid`
- terminal failure capture uses native class identity and message operations, so hostile `class`, `is_a?`, or `message` overrides cannot erase or weaken a durable failure record
- bounded UTF-8 failure text and JSON-safe details survive persistence; oversized details become explicit omission evidence instead of unbounded state
- a workflow that handled a failure and reached `:done` does NOT synthesize a stale error on terminal-restore (`build_run_result` synthesis is gated on `failed? && @last_failed_step`; successful subsequent steps clear the snapshot)
- `.persisted_state_exists?(key:, context:, adapter:)` peek: returns `false` when no state has been persisted; returns `true` after `persist!`; returns `false` again after `clear_persisted!`. Uses the existing private `resolved_persistence_key` + `fetch_persisted_payload` helpers — no `Smith::PersistenceAdapter` contract change
- `.restorable_billing_state?(key:, context:, adapter:)` peek (usage-aware): returns `false` for absent state, `false` for bare initial-state persistence (the record Smith writes at the top of `run_persisted!` BEFORE the first `advance!` — zero `usage_entries`), `true` once at least one `UsageEntry` has been recorded (preserved accounted work), `false` again after `clear_persisted!`
- the bare initial-state regression case is the load-bearing one: a worker that dies between Smith's initial `persist!` and the first `advance!` leaves a Redis key with no accounted work, and a host admission/accounting guard keyed on `persisted_state_exists?` alone could silently treat that abandoned-init-state replay as already authorized. `restorable_billing_state?` returns false on that state so the host guard can run.

Notes:

- This spec covers the durable contract surface only — recording itself (the `record_usage` call site contract) is covered in `spec/smith/workflow/usage_recording_spec.rb`.
- The two peek APIs are layered: `persisted_state_exists?` is a fast key-presence check; `restorable_billing_state?` is heavier (full deserialize) but answers the usage-aware question hosts need for accounting or admission-control checks.

### `spec/smith/workflow/usage_recording_spec.rb`

Purpose:

- asserts the contract between the lifecycle's `record_usage` helper and the workflow's `@usage_entries` / `@total_tokens` / `@total_cost` state, including parallel-fan-out attribution and nested-workflow rollup

Architecture basis:

- Section 4.2, Workflow
- Section 5.1, Agent Invocation
- Section 4.8, Observability (cost tracking)

Documented contracts covered:

- `record_usage` from the completed-attempt site (`snapshot_and_finalize`) appends a `:completed_attempt` `UsageEntry` carrying every per-call fact (`usage_id` / `agent_name` / `model` / token counts / `cost` / `recorded_at`)
- `record_usage` from the failed-attempt site (`account_failed_attempt`) appends a `:failed_attempt` `UsageEntry` when the provider call resolved with token usage before failing (failed-but-billable fallback path)
- `record_usage` is a no-op when `agent_result.usage_known?` is false — no entry, no token/cost change
- `record_usage` updates `@total_tokens`, `@total_cost`, and `@usage_entries` in lockstep inside ONE `@usage_mutex.synchronize` block (regression: prior two-block pattern allowed parallel-fan-out interleave between tokens and cost)
- sum invariant `total_tokens == sum(usage_entries.input_tokens + output_tokens)` and `total_cost ≈ sum(usage_entries.compact.cost)` (float-tolerant) holds across multiple recordings
- under concurrent recording from many threads with different model ids, every entry attributes the right `model` (regression guard for the local-arg `model_used` fix that replaced the prior `@last_attempt_model` ivar — the ivar version raced under fan-out and could attribute branch A's success to branch B's last-set model)
- under concurrent recording, the rollup invariant (`@total_tokens` + `@total_cost` + `@usage_entries.size`) is preserved — no lost updates, no double-counting
- nested-workflow rollup via `roll_up_child_totals`:
  - rolls up child `usage_entries` into the parent
  - deep-copies child entries (parent and child entries are different `UsageEntry` instances; Struct fields like `model` are different String objects via `snapshot_value`'s recursive duplication)
  - preserves `attempt_kind` on rollup so a child's `:failed_attempt` entry stays `:failed_attempt` on the parent

Notes:

- Drives `record_usage` directly via `send(:record_usage, ...)` and `roll_up_child_totals` via `send(...)` rather than mocking a full provider call. The helper contracts are the units under test, not the chat plumbing.
- The parallel-attribution test creates a fake agent class that responds to `register_as`; it does not require a real `Smith::Agent` subclass.

### `spec/smith/workflow/context_persistence_spec.rb`

Purpose:

- asserts that workflow serialization respects `Smith::Context.persist`

Architecture basis:

- Section 4.6, Context Manager
- Section 5.3, State Serialization

Documented contracts covered:

- `persist` keys control which workflow context keys are serialized in `to_state`
- `.from_state` restores only the persisted context keys
- persisted workflow session history round-trips through `to_state` / `.from_state`
- injected-state session messages persist as part of stored session history

Notes:

- This spec covers persisted-key filtering plus persisted session-history round-trip behavior.
- It does not yet assert broader masking behavior beyond the current stored-history surface.

### `spec/smith/workflow/parallel_spec.rb`

Purpose:

- asserts the workflow-visible parallel execution behavior exposed by the runtime

Architecture basis:

- Section 5.2, Workflow Execution
- Section 4.4, Guardrails
- Section 4.6, Context Manager

Documented contracts covered:

- parallel transitions return one branch result per configured branch on success
- callable branch counts derive from workflow context
- branch failure routes workflow execution through `on_failure`
- sibling branches observe cooperative cancellation at the post-execute check boundary
- in-flight branch work completes but its output is discarded on step failure
- successful branch outputs are discarded when the parallel step fails
- prepared input is reused across parallel branch execution
- workflow-attached tool guardrails remain visible inside parallel branch threads
- a host's `run_branch` runs in each branch and restores its context after a failure and a cancellation, its wait bounded so a branch that never calls it fails the example rather than hanging the suite (Unreleased)

Notes:

- This spec covers workflow-visible parallel behavior, prepared-input reuse, and attached tool-guardrail visibility in branch threads.
- It now asserts the parallel branch budget reservation/reconcile/release lifecycle, including:
  - token reservation floor behavior under small limits
  - reservation denial before branch work when budget would be exceeded
  - token reconciliation from response metadata
- It now also asserts:
  - remaining-budget-based parallel estimates after prior serial consumption
  - serial reservation/reconcile/release behavior at the workflow boundary
  - reconcile-on-failure when Smith-side `after_completion` raises after a successful provider response
  - agent-only `token_limit` enforcement without a workflow budget
  - agent-only `cost` enforcement without a workflow budget
  - agent-only parallel budgets behaving as per-branch invocation ledgers rather than a shared pool
- It does not yet assert richer provider-style in-flight completion behavior or provider-timeout optimistic release behavior beyond the current cooperative cancellation and failure/discard surface.

### `spec/smith/workflow/deterministic_step_spec.rb`

Purpose:

- asserts the deterministic step primitives (`compute` / `run`) — DSL contract, conflict validation against agent-bearing transition modes, runtime step-object surface, persistence round-trip, trace lifecycle, guardrail-boundary integration, and mixed agent + deterministic workflow behavior

Architecture basis:

- Section 5.2, Workflow Execution (Deterministic step primitives)
- Section 5.3, State Serialization (deterministic step persistence round-trip)
- Section 4.4, Guardrails (deterministic-step guardrail boundary)
- Section 4.8, Observability (deterministic-step trace lifecycle)

Documented contracts covered:

- `compute` DSL declares a workflow-resolved deterministic step bound to a workflow instance method or registered helper
- `run` DSL declares a host-resolved deterministic step bound to a registered host helper
- mutual-exclusivity validation rejects combining `compute` / `run` with any of: `execute`, `route`, `workflow`, `optimize`, `orchestrate`. Validation is bidirectional (declaring agent first then `compute`, or `compute` first then agent, both fail at DSL definition time)
- step-object runtime surface (constrained, host-facing): `read`, `read_context`, `write_context`, `write_outcome`, `route_to`, `fail!`, `tool_results` exposed as the documented step API; non-listed accessors are NOT part of the contract
- `read_context` reads the current context including any `write_context` writes made earlier in the same step (read-after-write coherence within a single step body)
- `write_outcome` records first-class run-result accessors (`outcome`, `outcome_kind`, `outcome_payload`) as part of the step's success path
- `route_to` chooses a named transition from the available next-transitions; an unresolved name fails loudly with `Smith::WorkflowError`
- optional deterministic route annotations via `compute(routes: [...])` and
  `run(routes: [...])` declare inspectable allowed `route_to` targets; malformed
  annotations fail at DSL definition time, graph validation reports unresolved
  annotated targets, reachability includes annotated routes, and runtime rejects
  `step.route_to` targets outside the declared set
- `fail!` accepts a message and optional metadata payload; the failure routes through `on_failure`
- persistence round-trip: deterministic step state survives `to_state` / `from_state` and resumes correctly mid-workflow
- trace lifecycle emits `outcome` `:started` / `:success` (with the emitted outcome kind) / `:routed` / `:failed` at the deterministic-step boundary, never the reserved `result` key; a failure carries `error_class`, `error_family` and `retryable` when known, never the raw message (mutation-verified)
- declared routes must be taken: a step with `routes:` whose target state has an outgoing transition and that does not route raises `Smith::UnroutedDeterministicStep`, keeps none of its writes, routes through `on_failure`, and escapes `run!` without one; `on_success` (also outside the routes) or `fallthrough: true` permit finishing unrouted, and a terminal target state ends the run there; `fallthrough: true` without `routes:` or a non-boolean value fails at definition time; graph reachability (including `on_success`) and transition snapshots (`deterministic_fallthrough`) follow the same rule; the failure record restores (all mutation-verified against the full suite)
- an explicit `persist :a, :b` list is an allow-list in every run: any other key raises `Smith::UndeclaredContextKey` at the write, before the rest of the step runs, and still fails the step when the step body rescues it; `persist :auto` and unmanaged workflows accept any key; `persist` refuses non-Symbol keys at definition time; hooks that write the live context (`after_completion`) are checked at the end of the step, a String or undeclared new key fails it and restores the context's top-level values, and nested values they write are normalized (all mutation-verified against the full suite)
- context shape: `Workflow.new` and the class-level helpers that derive a persistence key (`restore_or_initialize`, `persisted_state_exists?`, `restorable_billing_state?`) refuse String top-level keys, so a `persistence_key` builder sees the same context on every path and distinct runs keep distinct keys; every nested key becomes the Symbol of its String form (Integer keys included) at construction, at the write (so `read_context` in the same step sees it), and on JSON restore; colliding keys, self-containing values and nesting deeper than 100 levels fail the write with distinct messages (all mutation-verified against the full suite)
- guardrail boundary enforcement applies workflow-level input/output guardrails around deterministic step execution
- mixed-mode workflows: a workflow can interleave deterministic steps with agent-driven steps, sharing context, session messages, tool results, and budget ledger across both kinds

Notes:

- The deterministic step primitives are the host's escape hatch for non-LLM logic that must run inside the workflow lifecycle (deterministic decisions, host-policy gates, structured transformations on agent output).
- `compute` is workflow-resolved (instance method on the `Workflow` subclass); `run` is host-resolved (registered host helper). Both share the same constrained step-object surface so step bodies are interchangeable.
- This is one of Smith's largest spec files (~1150 lines, ~50 examples) — covers DSL declaration, runtime semantics, persistence, trace, guardrails, and mixed-mode integration in one place.
- `compute` / `run` are not first-class deterministic repair,
  polling/wait, or guarded state re-entry loop contracts. Route annotations make
  handwritten deterministic routing inspectable and enforceable, but Smith does
  not yet expose reusable loop policy metadata, persisted attempt/wake ledgers,
  or native graph diagnostics for those contracts.

### `spec/smith/workflow/fanout_spec.rb`

Purpose:

- asserts native heterogeneous multi-agent fan-out/fan-in transition behavior

Architecture basis:

- Section 5.2, Workflow Execution
- Section 11, Phase 3 Workflow Patterns

Documented contracts covered:

- `fan_out branches:` declares a bounded branch set with stable branch keys and
  distinct agent registry keys
- DSL validation rejects malformed branches and mixed execution primitives
- branch execution returns ordered named branch results under one transition
- branch failures discard partial output and route through normal failure
  handling
- workflow guardrails run once around the transition while agent guardrails run
  per branch
- branch agent input guardrails run before session preparation, so rejected
  fan-out branches cannot inject or persist session state before admission
- graph inspection exposes `kind: :fanout` and the branch map
- graph inspection exposes richer fan-out metadata: branch count, join state,
  ordered branch list, output contract, resume contract, and per-branch named
  result contracts

Notes:

- Use `execute :agent, parallel: true` for homogeneous same-agent branches.
  Use `fan_out` when branches are distinct specialist agents.

### `spec/smith/events/contract_spec.rb`

Purpose:

- asserts the typed event-bus surface
- verifies scoped subscriptions and cancellation handles

Architecture basis:

- Section 4.3, Events
- Section 11, Phase 1 Foundation

Documented contracts covered:

- `Smith::Event`
- `Smith::Events.on`
- `Smith::Events.within`
- subscription handle with `#cancel`

Notes:

- This spec covers API surface only.
- It does not yet assert best-effort rescue semantics, step-scoped emission, or non-authoritative behavior.

### `spec/smith/events/scoping_spec.rb`

Purpose:

- asserts the extra event subscription forms explicitly shown in the architecture

Architecture basis:

- Section 4.3, Events

Documented contracts covered:

- filtered subscription via `if:`
- scoped subscription object yielded by `Smith::Events.within`
- `scope.on`

Notes:

- This spec intentionally checks declaration and subscription surface only.
- It does not yet assert dispatch-time predicate behavior.

### `spec/smith/events/schema_spec.rb`

Purpose:

- asserts the typed event-schema declaration shape shown explicitly in the architecture

Architecture basis:

- Section 4.3, Events

Documented contracts covered:

- `Smith::Event.attribute`
- `Smith::Types::String`
- `Smith::Types::Integer`
- inherited event correlation fields:
  - `execution_id`
  - `trace_id`
- instantiated typed events carry `execution_id` and `trace_id` values

Notes:

- This spec checks schema declaration surface, not event dispatch/runtime serialization.

### `spec/smith/events/runtime_spec.rb`

Purpose:

- asserts runtime lifecycle behavior that is already exposed by the event bus surface

Architecture basis:

- Section 4.3, Events

Documented contracts covered:

- scoped subscriptions auto-cancel on block exit
- filtered subscriptions retain the declared predicate
- explicit subscription cancellation marks the handle as cancelled
- subscriptions are retained in registration order
- `reset!` clears registered subscriptions
- direct event dispatch preserves subscription order
- direct event dispatch respects event-class and predicate filtering
- direct event dispatch rescues and logs handler failures without aborting dispatch

Notes:

- This spec covers direct dispatch through the now-exposed event bus seam.
- It now asserts successful-step-only emission from workflow execution.
- It now asserts typed workflow step-event specificity and base-subscriber compatibility.

### `spec/smith/budget/contract_spec.rb`

Purpose:

- asserts the ledger contract that the architecture treats as a central safety boundary

Architecture basis:

- Section 4.5, Budget Controller
- Section 5.2, Workflow Execution
- Section 5.5, Assumptions
- Section 5.6, Error Hierarchy

Documented contracts covered:

- `Smith::Budget::Ledger`
- `Smith::Budget::Reservation`
- `#reserve!`
- `#reserve_many!`
- `#reconcile!`
- `#reconcile_many!`
- `#release!`
- `#release_many!`
- `Smith::BudgetExceeded`

Behavior currently asserted:

- reservation checks against committed plus reserved usage
- reconciliation frees prior reservation and charges actual usage
- release frees reservation on failure/cancellation paths
- denied reservation leaves available capacity unchanged
- lower actual usage frees the unused reserved portion
- dimensions are tracked independently
- reservation receipts are ledger-owned, one-shot, and identity-fenced
- multi-dimensional reservation, reconciliation, and release publish atomically
- finite non-negative Integer and Float inputs use exact internal decimal
  accounting while public and persisted ledger snapshots remain JSON-safe
- custom Numeric objects and non-JSON-safe numeric classes fail before mutation
- unknown dimensions and non-finite arithmetic results fail before state changes
- mutable caller identifiers and numeric objects are not retained directly

Notes:

- The spec uses `Ledger.new(limits:)` to construct the ledger through the public initializer.

### `spec/smith/budget/host_ledger_spec.rb`

Purpose:

- asserts what `Smith::Budget::HostLedger.amount(usage, model:, provider:, mode:)` asks of a host's usage object and how it prices it

Architecture basis:

- `docs/BUDGETS.md`, Budget ledgers (a host that settles a charge itself)

Documented contracts covered:

- a usage that answers only `input_tokens`, `output_tokens`, `cache_read_tokens` and `cache_write_tokens` (a `Data`, a `Struct`, a plain object, a `BasicObject`, a `RubyLLM::Message`) is priced as 0.15.0 priced it, with no images
- the image counts a usage carries (`image_input_tokens`, `image_output_tokens`) are priced at the catalog's image rates, for a host's `Struct`, a `BasicObject` and Smith's own `ProviderUsage` alike, and a usage answering only one of them is priced with that one
- only an image count the usage answers publicly counts: a private reader is neither called nor counted
- a usage with a `respond_to?` of its own is asked it: a `Minitest::Mock`-shaped usage, a class overriding `respond_to?` and a proxy forwarding it, each answering through `method_missing` with no `respond_to_missing?`, are priced with their image counts as on 0.16.0 and with four counts as on 0.15.0
- a forwarding `BasicObject` with no `respond_to?` or `respond_to_missing?` of its own, as Ruby sees it, is priced as `Kernel#respond_to?` sees it: with no image counts
- an image count that is nil, negative or not an Integer counts as none

### `spec/smith/context/contract_spec.rb`

Purpose:

- asserts the workflow-attached context-manager surface

Architecture basis:

- Section 4.6, Context Manager
- Section 5.1, Agent Invocation

Documented contracts covered:

- `Smith::Context`
- `.session_strategy`
- `.persist`
- `.inject_state`
- workflow-level `.context_manager`
- `.persist` on a context that declared no keys, `Smith::Context` itself among them, reads `[]`, not nil (Unreleased)

Notes:

- This spec deliberately checks only the declaration surface.
- It does not yet assert masking semantics, injected-state replacement, or persistence filtering behavior.

### `spec/smith/context/runtime_spec.rb`

Purpose:

- asserts the documented stored context configuration and formatter behavior exposed by `Smith::Context`

Architecture basis:

- Section 4.6, Context Manager

Documented contracts covered:

- `session_strategy` returns the declared observation-masking configuration
- `persist` returns the declared workflow context keys
- `inject_state` stores a callable formatter over persisted state
- subclasses inherit persisted keys by copy without mutating the parent
- subclasses can override `inject_state` without mutating the parent
- injected state merges into the existing agent-instruction system message before provider call
- workflow-prepared input preserves a single control-plane `system` message and leaves turn-local metadata in normal conversational roles
- accepted workflow output is appended to stored session history after successful step completion
- workflow-prepared input that would end with an accepted assistant turn receives
  a Smith-authored user continuation for the provider call only, preserving
  stored assistant history while avoiding unsupported assistant-prefill handoff
  on providers/models that require the request to end with a user turn
- provider-safe continuation recognizes string roles restored through JSON,
  ignores trailing system messages when finding the conversational turn, does
  not mutate shared prepared input, and is derived independently per invocation;
  restored string-key content remains available to system-message merging
- explicit assistant-prefill seed messages remain unchanged unless the trailing
  assistant content matches Smith's recorded accepted workflow output
- accepted falsy workflow output is also preserved in stored session history
- rejected output is not appended when output guardrails fail

Notes:

- This spec covers stored configuration, formatter behavior, prepared-input masking, accepted-output session append behavior, message persistence, replacement of injected state on repeated preparation, and the prepared-input seam consumed by workflow execution.
- It does not yet assert any broader call-path richness beyond the current workflow-driven `.complete` integration.

### `spec/smith/tools/contract_spec.rb`

Purpose:

- asserts the tool base class and the tool-author contract

Architecture basis:

- Section 5.1, Agent Invocation
- Section 6, Tool Governance
- Section 11, Phase 1 Foundation

Documented contracts covered:

- `Smith::Tool < RubyLLM::Tool`
- `.category`
- `.capabilities`
- `.authorize`
- tool authors define `perform`, not `execute`

Notes:

- This spec does not yet assert the approval metadata boundary or retriable-vs-terminal failure behavior.

### `spec/smith/tools/bounded_completion_context_spec.rb`

Purpose:

- proves bounded graceful tool completion through RubyLLM's real 1.16 chat
  recursion rather than a Smith-owned simulation

Documented contracts covered:

- exact model-request budgets and tool-disabled final synthesis
- all-or-nothing oversized provider batches with one paired rejection per call
- unavailable calls consume allowance without executing a Smith tool
- host-rejected invalid input remains bounded
- nested Smith tools cannot reuse the outer call admission
- provider failure restores chat controls and permits an explicit later attempt
- concurrent completion on one bounded chat fails closed
- provider snapshots and RubyLLM instrumentation observe the effective tool
  controls, and the original chat configuration is restored
- a single-call provider hint is emitted only when the model registry or the
  selected Responses endpoint supports tool-call cardinality; Smith's local
  all-or-nothing admission remains authoritative when the hint is omitted

Notes:

- These are in-process protocol guarantees. Durable per-invocation tool-loop
  recovery remains a host concern.

### `spec/smith/tools/call_allowance_spec.rb`

Purpose:

- proves atomic single-call and complete-batch allowance consumption

Documented contracts covered:

- concurrent callers cannot exceed the configured allowance
- an oversized batch is not partially consumed
- cancellation before lock acquisition cannot consume allowance
- independent legacy allowances do not share a serialization lock

### `spec/smith/tools/runtime_spec.rb`

Purpose:

- asserts runtime behavior at the existing `Smith::Tool#execute` seam

Architecture basis:

- Section 5.1, Agent Invocation
- Section 6, Tool Governance

Documented contracts covered:

- Smith-owned `execute` delegates to user-defined `perform` after enforcement
- tool arguments flow through `execute` into `perform`
- authorization receives the passed runtime context
- failed authorization prevents `perform` from running

Notes:

- This spec covers delegation behavior only.
- It does not yet assert the retriable `Smith::ToolGuardrailFailed` distinction or attached-guardrail sourcing paths, which are covered separately in `spec/smith/tools/failure_policy_spec.rb`.

### `spec/smith/tools/capabilities_spec.rb`

Purpose:

- asserts the capability metadata declaration shape described in tool governance

Architecture basis:

- Section 6, Tool Governance

Documented contracts covered:

- `capabilities do ... end`
- `sensitivity`
- `privilege`
- `network`
- `approval`
- `data_volume`

Notes:

- This spec only checks that the metadata can be declared in the documented shape.
- Policy effects are now partially covered elsewhere:
  - `sensitivity` now affects tool trace behavior
  - `privilege` now affects baseline tool policy gating
  - `data_volume` now affects workflow-boundary handoff shape for unbounded outputs
  - `network` now supports host-hook denial based on declared egress class

### `spec/smith/tools/builtins_spec.rb`

Purpose:

- asserts the built-in tool namespaces named in the gem structure

Architecture basis:

- Section 7, Gem Structure

Documented contracts covered:

- `Smith::Tools`
- `Smith::Tools::WebSearch`
- `Smith::Tools::UrlFetcher`
- `Smith::Tools::Think`

Notes:

- This spec checks namespace presence only.
- It does not yet assert built-in tool behavior.

### `spec/smith/tools/failure_policy_spec.rb`

Purpose:

- asserts the documented distinction between terminal policy failures and advisory approval metadata

Architecture basis:

- Section 5.6, Error Hierarchy
- Section 6, Tool Governance

Documented contracts covered:

- authorization denial raises `Smith::ToolPolicyDenied`
- approval metadata alone does not block execution without a host hook
- pre-dispatch hook denial raises `Smith::ToolPolicyDenied`
- workflow-attached tool guardrails can raise `Smith::ToolGuardrailFailed`
- agent-attached tool guardrails can raise `Smith::ToolGuardrailFailed`
- tool-guardrail failure prevents `perform`

Notes:

- This spec now covers the terminal-vs-retriable distinction at the tool boundary and both workflow-attached and agent-attached tool-guardrail sourcing paths.
- It now distinguishes the named `"malformed args"` and `"rate limit"` variants of retriable failure at the workflow boundary.
- It now also covers host-hook denial based on declared `network` metadata.

### `spec/smith/guardrails/contract_spec.rb`

Purpose:

- asserts the three-layer guardrail declaration surface and its attachment points

Architecture basis:

- Section 4.4, Guardrails
- Section 5.4, Guardrail Attachment
- Section 11, Phase 2 Guardrails and Context

Documented contracts covered:

- `Smith::Guardrails`
- `.input`
- `.tool`
- `.output`
- attachment to `Smith::Agent`
- attachment to `Smith::Workflow`
- workflow-level guardrails run before agent-level guardrails during workflow execution

Notes:

- This spec primarily covers declaration surface and attachment points.
- It now also covers the runtime requirement that workflow-level guardrails precede agent-level guardrails.
- It does not yet assert full blocking/failure semantics or tool guardrail execution.

### `spec/smith/guardrails/order_spec.rb`

Purpose:

- asserts the documented declaration ordering within the three guardrail layers

Architecture basis:

- Section 4.4, Guardrails

Documented contracts covered:

- input declarations preserve order
- tool declarations preserve order and options
- output declarations preserve order and options

Notes:

- This spec covers layer ordering as declared.
- It does not yet assert runtime execution ordering across workflow-level and agent-level guardrails.

### `spec/smith/guardrails/runtime_spec.rb`

Purpose:

- asserts the runtime execution behavior of the guardrail pipeline at the workflow boundary — input blocking, output blocking, success-event suppression on guardrail failure, and cooperative-deadline failure routing

Architecture basis:

- Section 4.4, Guardrails (synchronous blocking, on_failure routing)
- Section 5.4, Guardrail Attachment

Documented contracts covered:

- input guardrail failure blocks step execution (the agent's `execute` body is NOT invoked) and routes the workflow through `on_failure`
- output guardrail failure runs AFTER the agent body and then routes through `on_failure`; the recorded order is `executed → output_guardrail`
- guardrail failures surface as `Smith::GuardrailFailed` on the failed step's `:error` payload
- a guardrail failure that routes the workflow to `:failed` does NOT emit a success event (the typed event bus only fires on successful steps)
- cooperative `wall_clock: 0` deadline expiry BEFORE the agent call routes through `on_failure` with a `Smith::DeadlineExceeded` error carrying the documented message `"wall_clock deadline exceeded"`; `chat.complete` is never invoked when the deadline has already expired

Notes:

- Covers runtime semantics of the guardrail pipeline; declarative attachment ordering is asserted in `spec/smith/guardrails/order_spec.rb`.
- Cooperative deadline coverage here is the workflow-level seam; per-budget cooperative cancellation is asserted in the budget specs.

### `spec/smith/guardrails/builtins_spec.rb`

Purpose:

- asserts the built-in URL verifier namespace named in the architecture

Architecture basis:

- Section 7, Gem Structure
- Section 11, Phase 2 Guardrails and Context

Documented contracts covered:

- `Smith::Guardrails::UrlVerifier`

Notes:

- This spec checks namespace presence only.

### `spec/smith/trace/contract_spec.rb`

Purpose:

- asserts the trace adapter namespace surface promised by the architecture

Architecture basis:

- Section 4.8, Observability
- Section 11, Phase 1 and Phase 4 Roadmap

Documented contracts covered:

- `Smith::Trace`
- `Smith::Trace::Memory`
- `Smith::Trace::Logger`
- `Smith::Trace::OpenTelemetry`

Notes:

- This spec covers namespace presence only.
- Payload and content-policy behavior are covered separately in `spec/smith/trace/runtime_spec.rb`.

### `spec/smith/trace/runtime_spec.rb`

Purpose:

- asserts the runtime content-policy behavior exposed by the in-memory trace adapter

Architecture basis:

- Section 4.8, Observability

Documented contracts covered:

- structural trace data is recorded by default while content fields are omitted
- `trace_content = :redacted` masks string content fields
- `trace_content = :redacted` masks only content fields (`content`, `prompt`, `response`, `args`, `result`) in the Memory, Logger and OpenTelemetry adapters, every String and Symbol at any depth of Hashes and Arrays, leaving identifiers such as `model`, `execution_key`, `error_class` and `tool` readable (mutation-verified per adapter and per masking rule)
- a deterministic step's failure trace is classified only when a trace adapter is configured, keeps the step's error when classification raises, and an error whose `details` and inner message both raise keeps its own class with or without tracing (mutation-verified)
- `trace_content = true` retains full content
- structural trace type toggles disable recording for the relevant trace category
- `trace_fields` filters transition trace payload fields
- `trace_fields` filters tool-call trace payload fields
- unknown `trace_fields` entries are ignored
- unconfigured trace types remain unchanged
- successful workflow agent call emits a `token_usage` trace with observed input/output token counts
- `trace_token_usage = false` suppresses `token_usage` emission
- provider failure before usage is known does not emit `token_usage`
- successful provider response that lacks usage metadata does not emit `token_usage`
- successful provider response with only partial usage metadata does not emit `token_usage`
- successful provider response followed by `after_completion` failure still emits `token_usage` when both counts are present

Notes:

- This spec covers adapter-level runtime behavior plus runtime trace emission from successful workflow steps, tool execution, and token usage, including class-configured adapter support and best-effort adapter failure handling.
- It asserts the documented `trace_fields` filtering behavior for emitted trace types.
- All three guaranteed built-in trace types (`transition`, `tool_call`, `token_usage`) are now covered.

### `spec/smith/artifacts/contract_spec.rb`

Purpose:

- asserts the artifact-store namespace and the built-in backends shown explicitly in the architecture

Architecture basis:

- Section 4.7, Artifact Store
- Section 11, Phase 4 Production Readiness

Documented contracts covered:

- `Smith::Artifacts`
- `Smith::Artifacts::Memory`
- `Smith::Artifacts::File`
- top-level accessor `Smith.artifacts`

Notes:

- This spec covers entry points only.
- It does not yet specify `store`/`fetch` semantics, retention behavior, or namespace isolation.

### `spec/smith/artifacts/operations_spec.rb`

Purpose:

- asserts the named artifact-store operational methods shown in the architecture examples

Architecture basis:

- Section 4.7, Artifact Store

Documented contracts covered:

- `Smith.artifacts.store`
- `Smith.artifacts.fetch`
- `Smith.artifacts.expired`
- `Smith.artifacts` resolves to the configured artifact store instance

Notes:

- This spec checks named operational surface and configured-store resolution only.
- It does not yet assert namespace isolation, opaque ref semantics, or garbage-collection behavior.

### `spec/smith/artifacts/lifecycle_spec.rb`

Purpose:

- asserts the documented basic lifecycle behavior of the in-memory artifact backend

Architecture basis:

- Section 4.7, Artifact Store

Documented contracts covered:

- storing returns an opaque ref
- fetching returns stored content
- expired refs are discoverable through `expired(retention:)`
- execution-scoped backend writes and expiry filtering are supported through the scoped artifact-store interface
- fresh refs are not reported as expired
- separate payloads produce distinct opaque refs
- separate store instances do not share stored data
- namespace-prefixed refs are supported
- identical payloads stored in different namespaces yield different refs

Notes:

- This spec covers the in-memory backend only.
- The artifact contract spec also covers the execution-scoped wrapper/backend interface used for namespaced handoff and expiry filtering.

## Uncovered Contracts by Architecture Section

These are not gaps in the architecture review. They are uncovered or only partially covered contracts in the current RSpec suite.

### Section 4.2 Workflow

Not yet directly specified:

- narrow resume semantics
- host-owned idempotent step boundaries

Recommended future specs:

- `spec/smith/workflow/resume_spec.rb`

### Section 4.3 Events

Not yet directly specified:

- host progress callbacks are outside Smith’s event contract

Recommended future specs:

- none beyond broader host-callback integration, unless new runtime seams are added

### Section 4.4 Guardrails

Partially covered:

- input guardrails run before model/tool execution at runtime
- output guardrails run after model completion at runtime (with the executed-then-output-guardrail order asserted explicitly via an observation list)
- input and output guardrail failures route workflow execution through `on_failure`, surfacing `Smith::GuardrailFailed` on the failed step's `:error` payload
- guardrail-induced workflow failures do NOT emit a success event (the typed event bus only fires on successful steps)
- tool guardrail ordering at invocation time
- cooperative pre-agent-call deadline failure routing is covered (carries `Smith::DeadlineExceeded` with the documented `"wall_clock deadline exceeded"` message; `chat.complete` is never invoked when the deadline has already expired)
- tool-boundary retriable guardrail failure semantics are covered at the workflow boundary
- no async output validation leakage

Recommended future specs:

- extend `spec/smith/guardrails/order_spec.rb` only if additional stable seams are added

### Section 4.5 Budget Controller

Partially covered:

- ledger API is covered
- denied reservation state preservation is covered
- lower-actual reconciliation behavior is covered
- multi-dimension independence is covered
- estimate-based parallel token reservation/reconcile/release behavior is covered at the workflow boundary
- serial token reservation/reconcile/release behavior is covered at the workflow boundary
- cooperative `wall_clock` deadline behavior is covered at Smith-owned call boundaries
- agent-only `token_limit` / `cost` enforcement is covered in parallel invocation paths
- agent-only parallel token/cost budgets are covered as per-branch invocation constraints rather than a shared branch pool
- post-response Smith-side failure reconciliation from observed usage is covered
- persisted `budget_consumed` now reflects live ledger state
- restored workflows rebuild a live ledger and continue budget reservation/reconciliation from restored state
- provider-timeout optimistic release semantics are not yet covered

Recommended future specs:

- add `spec/smith/budget/runtime_spec.rb` to directly lock:
  - workflow / agent `tool_calls` enforcement at the tool boundary
  - agent-only `token_limit` / `cost` enforcement in serial/helper-owned invocation paths
  - any sharper distinction between generic call-boundary deadlines and agent-budget-specific `wall_clock` narrowing

### Section 4.6 Context Manager

Partially covered:

- DSL is covered
- stored session strategy / persist / inject_state formatter behavior is covered
- subclass inheritance/override behavior is covered
- prepared-input masking behavior is covered
- injected-state replacement on repeated preparation is covered
- persisted key filtering in `to_state`/`from_state` is covered
- the prepared-input seam consumed by workflow execution is covered

Recommended future specs:

- extend `spec/smith/context/runtime_spec.rb` only if broader workflow call-path richness is added

### Section 4.7 Artifact Store

Partially covered:

- namespace and built-in backends are covered
- top-level accessor is covered
- artifact store operational interface is covered at the method-surface level:
  - `store`
  - `fetch`
  - `expired`
- in-memory store/fetch/expiry behavior is covered
- fresh/non-expired behavior is covered
- distinct refs for distinct payloads are covered
- separate in-memory stores are isolated from each other
- namespace-prefixed refs are covered
- different namespaces producing different refs are covered
- same-content addressing within the same namespace is covered
- same-namespace fetch behavior is covered
- cross-namespace fetch isolation is covered
- namespace-scoped expired-query behavior is covered
- namespace-scoped content addressing is covered in the memory backend
- retention fallback and tenant-isolation namespace enforcement are covered in the memory backend
- scoped wrapper expired queries are covered for shared-backend execution ownership
- artifact handoff references are covered at the workflow output boundary
- configured artifact backend preservation during handoff is covered
- execution-namespace stability across serialization is covered

Recommended future specs:

- extend the current artifact specs if broader host-level artifact handoff orchestration is added

### Section 4.8 Observability

Partially covered:

- trace namespaces are covered
- top-level configuration surface for trace setup is covered
- structural trace defaults are covered
- content tracing is covered as opt-in by default
- memory-adapter filtering behavior is covered
- built-in logger adapter runtime behavior is covered
- built-in OpenTelemetry adapter runtime behavior is covered
- OpenTelemetry graceful degradation when the dependency is unavailable is covered
- structural trace-type disabling is covered
- runtime transition trace emission is covered
- runtime tool-call trace emission is covered
- class-configured adapter support is covered
- best-effort adapter failure handling is covered
- `trace_fields` structural filtering is covered

### Section 5.1 Agent Invocation and Section 6 Tool Governance

Partially covered:

- `Smith::Agent` layering is covered
- `Smith::Tool` base contract is covered
- `Smith::Tool#execute` delegation/context/authorization-gate behavior is covered
- built-in tool namespace and tool entry points are covered
- top-level configuration surface used by artifacts/tracing is covered
- authorization-denied terminal behavior is covered
- approval-without-host-hook advisory behavior is covered
- cooperative pre-tool-call deadline enforcement is covered
- runtime `output_schema` participation in workflow agent execution is covered
- attached tool-guardrail visibility is covered at the workflow boundary, including parallel branch threads
- retriable `Smith::ToolGuardrailFailed` is covered at the workflow boundary for both workflow-attached and agent-attached guardrails, including the named `"rate limit"` and `"malformed args"` variants
- capability metadata policy effects are partially covered:
  - `approval` advisory behavior is covered
  - `sensitivity`-driven tool trace behavior is covered
  - `privilege` baseline gate behavior is covered
  - `data_volume` unbounded handoff-shape enforcement is covered
  - `network` host-hook enforcement via declared capability metadata is covered

### Section 5.2 Workflow Execution

Partially covered:

- `advance!`, `run!`, and DSL are covered
- `run!` result object shape is covered at the method-surface level
- real last-step workflow output is covered
- immediate-terminal and advance-until-terminal behavior are covered
- `on_success` runtime selection is covered
- wildcard `:fail` exclusion from normal transition lookup is covered
- workflow-level then agent-level guardrail participation is covered
- parallel branch count resolution, prepared-input reuse, workflow-level failure routing, discard-on-failure surface, attached tool-guardrail visibility, estimate-based parallel token budget enforcement, and agent-only parallel token/cost enforcement are covered
- serial token budget settlement and remaining-budget-based parallel estimation are covered
- cooperative pre-agent-call deadline enforcement is covered
- `MaxTransitionsExceeded` exception, current-state preservation, and non-resumable repeated/rehydrated behavior are covered
- deterministic step primitives (`compute` / `run`) DSL contract, mutual-exclusivity validation against agent-bearing modes (bidirectional for `execute`/`route`/`workflow`/`optimize`/`orchestrate`/`run`), constrained step-object surface (`read`/`read_context`/`write_context`/`write_outcome`/`route_to`/`fail!`/`tool_results`), persistence round-trip, trace lifecycle (`started`/`success`/`routed`/`failed` + emitted outcome kind), and guardrail-boundary enforcement are covered
- mixed agent + deterministic workflow integration (interleaved deterministic and agent-driven steps share context, session messages, tool results, and budget ledger) is covered
- per-agent-call usage facts (`Workflow::UsageEntry`) populated from completed AND failed-but-accounted attempts, with single-mutex critical section keeping `@total_tokens` / `@total_cost` / `@usage_entries` updates atomic, are covered
- nested-workflow `total_cost` / `total_tokens` / `usage_entries` rollup happens BEFORE the failed-step check raises (preserving failed-child accounted work on the parent) is covered
- terminal-restore correctness for `RunResult#output` (last-non-nil step output fallback gated on `steps.empty?`) and `RunResult#last_error` / `#failure_detail` (synthesized from class-aware `@last_failed_step` snapshot when steps is empty) is covered
- usage-aware durability peeks `Workflow.persisted_state_exists?` (fast key-presence) and `Workflow.restorable_billing_state?` (true only when restored state has `usage_entries.any?`) are covered

Recommended future specs:

- extend `spec/smith/workflow/parallel_spec.rb` only if richer provider-style branch semantics or provider-timeout budget behavior are added

#### Explicit Loop-Policy Boundary

This subsection is scoped to repair and wait-style loop policies. It does not
replace the bounded Orchestrator-Worker delegation contract covered earlier.

- Supported executable repair/wait-style loop contracts today:
  - local transition retry through `retry_on`
  - Evaluator-Optimizer refinement through `optimize`
- Expressible but not native:
  - deterministic repair can be handwritten with `compute` / `run` only when a
    workflow author explicitly owns the guard, repair action, revalidation
    target, attempt bounds, and unrepaired exit behavior; deterministic
    `routes: [...]` should be used to make any `route_to` targets inspectable
  - guarded state re-entry can be handwritten with `compute` / `run` only when
    the workflow author explicitly owns route targets and safety policy, and
    declares those targets with `routes: [...]`
- Not Smith-owned today:
  - polling/wait loops require a host queue/timer, persisted wake state, timeout
    and cancellation policy, and resume through Smith persistence helpers
- Architecture risk:
  - do not model durable polling/wait with sleeps, busy loops, or
    `max_transitions` cycling inside Smith
  - bounded local retry backoff remains part of the `retry_on` contract; it is
    not a durable polling/wake mechanism
  - do not claim a compiler-generated deterministic repair or guarded re-entry
    contract is executable until Smith has a native primitive or the host
    runtime contract is explicit and tested

Additional recommended future specs before adding native loop policies:

- `spec/smith/workflow/deterministic_repair_spec.rb`
- `spec/smith/workflow/guarded_reentry_spec.rb`
- `spec/smith/workflow/wait_contract_spec.rb`

Any native implementation must first update the architecture contract for
attempt/wake persistence, inspection metadata, failure/exhaustion semantics,
idempotent re-entry, and host-owned scheduler boundaries.

### Section 5.3 State Serialization

Partially covered:

- entry points are covered
- exact documented hash shape is covered (now including `usage_entries`, `last_output`, and `last_failed_step` keys; backward-compat fallbacks for pre-patch persisted state restore cleanly)
- typed `Workflow::UsageEntry` rebuild via `from_h` on restore is covered (host JSON round-trip safety with stringified-symbol coercion on `agent_name` / `attempt_kind`)
- terminal-restore correctness for `RunResult#output` / `#last_error` / `#failure_detail` via persisted `@last_output` / `@last_failed_step` snapshots is covered
- class-aware error reconstruction on `@last_failed_step` restore (`KNOWN_RECONSTRUCTORS` for known classes, `RETRYABLE_BEARING_FAMILIES` short-circuit for unknown subclasses of `DeterministicStepFailure`/`ToolGuardrailFailed`, `family_fallback` for unknown subclasses of other Smith error classes, `RuntimeError` for the `other` family) is covered
- eager `@usage_mutex = Mutex.new` mirror in `restore_state` (load-bearing — `from_state` uses `allocate` and bypasses `initialize`) is covered
- non-serialization guarantees are only partially covered

Recommended future specs:

- extend the workflow serialization/state-shape specs with deeper non-serialization guarantees if explicit rejection behavior is added

### Section 5.6 Error Hierarchy and Section 6 Tool Governance

Partially covered:

- error classes exist
- provider/LLM call failures are wrapped as `Smith::AgentError` at the workflow runtime boundary
- tool DSL exists
- terminal policy-denial behavior is partially covered
- retriable `Smith::ToolGuardrailFailed` runtime path is covered at the workflow boundary, including the named `"malformed args"` and `"rate limit"` variants
- approval metadata remains advisory without host hook is covered
- pre-dispatch hook denial behavior is covered
- host-level approval wiring semantics remain only partially covered

Recommended future specs:

- extend tool/runtime coverage only if a richer end-to-end tool loop becomes observable
- extend workflow runtime coverage only if provider/setup failure taxonomy is refined beyond the current `chat.complete` wrapping boundary

## Source-Backed Contracts to Protect Carefully

The following architecture areas are especially sensitive because they were repeatedly justified against external sources during review:

- workflow-first, bounded pattern hierarchy
- events as observational side effects, not orchestration authority
- synchronous guardrail boundaries
- opt-in content tracing
- explicit host-app responsibility for durability and approval flows
- loop-policy boundaries: no hidden durable waits, schedulers, or unbounded
  repair cycles inside Smith-owned workflow execution

When adding specs in these areas:

1. Re-read the architecture section first.
2. Re-check the surrounding summary tables and roadmap text.
3. Avoid encoding stronger behavior than the document claims.

## Section 8: Host Installation and Verification

### `spec/smith/doctor/report_spec.rb`

Covered behaviors:

- empty report is passed with exit_code 0
- report with :pass checks is passed
- report with one :fail check is failed with exit_code 1
- :warn without :fail is still passed
- summary counts all statuses correctly
- grouped groups by first name segment

### `spec/smith/doctor/checks/baseline_spec.rb`

Covered behaviors:

- all 6 baseline checks pass in test environment

### `spec/smith/doctor/checks/configuration_spec.rb`

Covered behaviors:

- warns when config.logger is nil, passes when set
- warns when config.pricing is nil, passes when populated

### `spec/smith/doctor/checks/serialization_spec.rb`

Covered behaviors:

- all 4 serialization checks pass (to_state, json_roundtrip, from_state, resume)

### `spec/smith/doctor/checks/durability_spec.rb`

Covered behaviors:

- warns when no persistence_adapter configured, naming the adapters word for word, and runs no other durability check (Unreleased)
- passes persist_restore and resume_after_restore with working adapter
- fails when adapter returns corrupted data
- resolves built-in symbol adapters via persistence_options
- fails cleanly when built-in adapter configuration is invalid
- fails cleanly when lazy cache-backed adapter resolution raises during backend warning evaluation
- warns when `:rails_cache` resolves to a process-local memory store
- warns when `:cache_store` wraps a process-local memory backend
- each example resolves the persistence adapter afresh: Smith keeps the one it resolved for a configuration and the examples swap `Rails`, so a guard last in file order fails when one an earlier example resolved reaches it
- fails the adapter check on every run while the configured adapter cannot be built, another configuration's adapter resolved before (Unreleased)

### `spec/smith/doctor/installer_spec.rb`

Covered behaviors:

- writes config/smith.rb for plain Ruby
- writes config/initializers/smith.rb when Rails detected
- does not overwrite existing file
- prints next steps
- generated install templates include symbol-based persistence adapter examples

### `spec/smith/doctor/checks/live_spec.rb`

Covered behaviors:

- provider_config warns (not fails) when no credentials detected
- model_call attempts call regardless of provider_config status
- model_call fails gracefully on StandardError

### `spec/smith/doctor_spec.rb`

Covered behaviors:

- default run includes baseline + config checks
- durability: true includes serialization + durability checks
- profile: :rails_persistence includes persistence checks
- live: true includes live checks
- the checks every profile runs come first, then the profile's own (Unreleased)

### `spec/smith/providers/openai/responses_spec.rb`

Covered behaviors:

- a Responses body that carries an error raises it with its response, though it has no output (Unreleased)
- a reasoning output's summary is read, not its content, when it has both (Unreleased)
- the system role goes out as `developer` unless the provider's config asks for `system` (Unreleased)

### `spec/smith/cli_spec.rb`

Covered behaviors:

- doctor command returns report exit_code
- version returns 0
- unknown command returns 1
- --help returns 0

### `spec/smith/tasks_spec.rb`

Covered behaviors:

- smith:doctor, smith:doctor:live, smith:doctor:durability, smith:install Rake tasks are defined

### `spec/smith/doctor/checks/persistence_spec.rb`

Covered behaviors:

- schema_presence skips when ActiveRecord not defined
- default/nil registry mode reports bundled fallback (pass)
- explicit :bundled registry mode passes with bundled messaging
- explicit :database registry mode fails when registry class is not resolvable
- explicit :database registry mode fails when registry class exists but is not ActiveRecord-backed
- explicit :database registry mode passes when the DB-backed registry class exists, table exists, and records are present
- explicit :database registry mode does not accept bundled JSON fallback as proof
- RubyLLM persistence surface detection warns when not detected

Notes:

- strict :database mode verifies the DB registry class directly via RubyLLM.config.model_registry_class
- bundled JSON fallback does not satisfy strict DB mode — RubyLLM.models facade is not used
- verification chain: resolve class → check AR ancestry → check table exists → check records present

### `spec/smith/doctor/checks/models_registry_spec.rb`

Covered behaviors:

- passes when registered static agent models are covered by Smith's provider-family inference rules
- passes when a host registers an explicit `Smith::Models::Profile`
- warns when registered static agent models would rely on safe-default shaping
- warns when static fallback models would rely on safe-default shaping, even
  when the primary model is dynamic
- skips block-form dynamic models because they resolve per workflow attempt

Notes:

- This check reports Smith-specific request-shaping coverage. RubyLLM's model registry can know a model exists while Smith may still not know the model's thinking/tool-routing semantics.

### `spec/smith/doctor/checks/persistence_capabilities_spec.rb`

Covered behaviors:

- warns (`persistence.capabilities`, status `:warn`) when `Smith.persistence_adapter` returns nil (no adapter configured and `test_mode` false)
- passes when the configured adapter supports all `OPTIONAL_METHODS`
  (`store_versioned`, `replace_exact`, `persistence_identity`,
  `record_heartbeat`, `last_heartbeat`,
  `transaction_open?`, `transaction_identity`); `Memory` qualifies directly,
  while `RedisStore` requires an explicit bounded `persistence_identity`
- warns with actionable detail when the adapter is missing optional capabilities, naming the missing capabilities and explaining the fallback semantics
- warns when `persistence_identity` exists as a method but its value is not a
  bounded, non-empty string

Notes:

- The check is wired into the `:rails_persistence` profile; the default `:auto` profile skips it. Hosts running under other profiles rely on runtime one-time Smith warnings and `Workflow.stuck_for?` fallback behavior to surface adapter capability gaps.

### `spec/smith/persistence_adapters_spec.rb`

Covered behaviors:

- nil resolves to no adapter
- custom adapter objects are passed through unchanged
- `:cache_store` resolves with provided store and namespace
- a `:cache_store` store given as a callable is built once for threads that first use the adapter together, each using that store; a source that failed is asked again on the next call, and one that asks its adapter for the store fails with a `Smith::Error` saying so (Unreleased)
- `:rails_cache` resolves through `Rails.cache`
- `:solid_cache` aliases to Rails-cache-backed resolution
- `:redis` resolves with provided client and namespace
- `:active_record` resolves with configured model and columns
- `:memory` resolves to `Smith::PersistenceAdapters::Memory` (in-process Hash adapter, test-friendly)
- custom adapter classes can be instantiated with keyword options
- invalid custom adapter classes fail contract validation
- unknown adapter symbols fail clearly
- `Smith::PersistenceAdapters::OPTIONAL_METHODS` includes `store_versioned`,
  `replace_exact`, `persistence_identity`, heartbeat methods,
  `transaction_open?`, and `transaction_identity`, all
  introspected via `supports?(adapter, capability)`
- `warn_missing_versioning(adapter)` issues a one-time per-adapter-class warning when an adapter does not implement `store_versioned`; subsequent calls are no-ops within the same Smith boot (Monitor-synchronized via class-level Set)

Notes:

- Serialization checks verify Smith-internal serialize/restore mechanics
- Durability checks verify host persistence adapter round-trip AND resumed execution from restored state
- Persistence checks are explicitly opt-in via --profile rails_persistence
- Live checks inspect RubyLLM.config, not hardcoded env vars
- CLI is framework-neutral; Rake tasks are Rails convenience wrappers
- Schema and model registry checks use honest messaging — heuristic results are labeled as such
- Built-in persistence adapters are configured via `config.persistence_adapter = :symbol` plus `config.persistence_options = {...}`
- `Smith.persistence_adapter` caches the resolved adapter until persistence config changes
- `:rails_cache` / `:solid_cache` can warn when the configured backend is only process-local memory
- in-place `persistence_options` mutation invalidates adapter caching via snapshot-based signatures
- `:cache_store` shares the same process-local memory warning behavior when the backend is detectable
- lazy cache-backed backend resolution failures are reported as `durability.adapter` failures instead of escaping the doctor run
- `Smith.config.test_mode = true` auto-selects the Memory adapter when `persistence_adapter` is nil, letting spec suites skip wiring Redis/Rails.cache in `spec_helper.rb`

### `spec/smith/persistence_adapters/active_record_store_spec.rb`

Purpose:

- pins the real Active Record adapter contract in the default test suite

Documented contracts covered:

- consecutive Smith writes compare `expected_version` with the stored payload's
  `persistence_version`, independently of the Rails row lock
- stale logical versions report the stored Smith version
- missing rows reject nonzero expected versions with `actual: :missing`
- mutable string column names are copied and frozen at initialization while
  symbol column names retain their established host-facing type
- an `ActiveRecord::StaleObjectError` is translated to
  `Smith::PersistenceVersionConflict` with `actual: :concurrent`
- legacy syntactically malformed payloads retain the established version-zero
  behavior while valid JSON scalars fail closed
- writes participate in an outer Active Record transaction/savepoint
- restart-safe dispatch claims participate in that transaction, remain
  non-executable before commit confirmation, and recover an exact rollback
- workflow persist/restore rejects a stale restored writer without advancing its
  in-memory persistence version
- custom host locking columns work when model and adapter agree
- mismatched or disabled host optimistic-locking configuration fails closed
- concurrent initial inserts are contained and translated without invalidating
  the caller's transaction
- key uniqueness validations are translated while unrelated unique constraints
  and callback rollbacks preserve their original Active Record meaning
- exact replacement validates key uniqueness before mutation and compares
  payload bytes independently of database text collation
- connection failures are translated without replaying the uncertain versioned
  write below the host-owned transaction boundary

### `spec/smith/workflow/split_step_load_spec.rb`

Purpose:

- pins direct aggregate load-order independence

Documented contracts covered:

- requiring `smith/workflow/split_step_persistence` directly loads its internal
  components without relying on `smith.rb` to preload implementation files

### `spec/smith/persistence_adapters/redis_store_spec.rb`

Purpose:

- pins fail-closed Redis compare-and-swap creation semantics

Documented contracts covered:

- a missing key rejects nonzero expected versions before `MULTI` and reports
  `Smith::PersistenceVersionConflict` with `actual: :missing`
- versioned and exact replacement use WATCH/MULTI/EXEC within the client's
  native no-reconnect scope, reject stale or concurrently changed payloads, and
  never replay an ambiguously acknowledged write
- callable Redis command clients are not mistaken for factories; clients that
  cannot disable reconnection fail before WATCH

### `spec/smith/persistence_adapters/payload_version_spec.rb`

Purpose:

- pins the shared logical-version parser used by versioned persistence adapters

Documented contracts covered:

- serialized JSON and decoded documents expose the same `persistence_version`
- missing versions and syntactically malformed payloads retain the established
  version-zero fallback; scalar payloads and explicit invalid versions fail
  closed

### `spec/smith/persistence_adapters/memory_spec.rb`

Purpose:

- pins the in-process Memory adapter contract: REQUIRED_METHODS compliance, TTL via stamped expiry, optional `store_versioned` and exact-payload `replace_exact` via Monitor synchronization, process-local persistence identity, thread-safety, and `Smith.persistence_adapter` test_mode auto-detect

Architecture basis:

- Section 5.3, State Serialization (test-friendly in-process adapter)

Documented contracts covered:

- responds to `store`, `fetch`, `delete` (REQUIRED_METHODS); passes `adapter_like?` validation
- `store(k, v)` then `fetch(k)` returns v; `fetch(missing)` returns nil; `delete(k)` removes
- TTL: entries written with `ttl: N` expire N seconds after write; `Smith.config.persistence_ttl` is the default; nil TTL means no expiry
- `respond_to?(:store_versioned)` is true; `Smith::PersistenceAdapters.supports?(adapter, :store_versioned)` reports true
- `store_versioned(k, v, expected_version: 0)` works on first write; subsequent writes require matching `expected_version`
- `store_versioned` raises `Smith::PersistenceVersionConflict` (with key/expected/actual fields) when expected_version is stale
- expired entries are treated atomically as missing during version comparison,
  so stale writers cannot revive them
- stored and fetched payload strings are copied, preventing caller mutation from
  bypassing the adapter monitor and optimistic version check
- missing entries reject nonzero expected versions with `actual: :missing`
- `replace_exact` changes only byte-identical current payloads and rejects
  missing, stale, and same-version-mutated values
- thread safety: concurrent writes serialize via Monitor; reads observe coherent state (no torn writes / nil races)
- `Smith::PersistenceAdapters.resolve(:memory)` returns a Memory instance
- `Smith.persistence_adapter` auto-detects: returns Memory when persistence_adapter nil + `test_mode` true; returns nil when persistence_adapter nil + test_mode false

Notes:

- `clear!` is exposed for test isolation; not part of the REQUIRED_METHODS contract.

### `spec/smith/persistence_adapters/retry_spec.rb`

Purpose:

- pins the generic `Smith::PersistenceAdapters::Retry.with_retries` wrapper: exponential backoff up to `policy.attempts`, distinct per-adapter transient-error lists, and `Smith::PersistenceIOError` on exhaustion

Architecture basis:

- Section 5.3, State Serialization (resilient persistence I/O)

Documented contracts covered:

- success on the first attempt returns the block result without retrying
- transient failure on attempt 1 succeeds on retry; block executed N times where N = attempts to first success
- exhaustion after `policy.attempts` raises `Smith::PersistenceIOError` with `#operation` and `#cause` fields
- non-transient errors raise immediately, no retry attempts
- each adapter passes its own `transient:` array: an adapter passing only Redis errors does NOT retry on Errno::EPIPE if not in its list
- `Smith.config.persistence_retry_policy` is the default policy when no policy kwarg is passed

Notes:

- retry policies are validated before adapter work begins
- attempts are positive and bounded by `Smith.config.retry_attempt_limit`
- delay controls are finite, real, and non-negative
- every realizable delay is bounded by Ruby's supported sleep interval
- delay calculation is constant-space and `O(1)` per attempt, with overflow-safe
  capping before exponentiation
- Backoff is exponential capped by `policy.max_delay`: delay = min(base * 2^attempt, max_delay).

## Section 9: Tool Result Capture

> **Cross-cutting feature index.** This section is a per-feature view of how `tool_results` capture is exercised across multiple specs — distinct from the file-by-file mapping above. The same files appear here when they contribute to this feature; the bullets below list ONLY the capture-related behaviors, not the full file's coverage. Refer to each file's primary section earlier in this document for the complete contract list.

### `spec/smith/tools/contract_spec.rb`

Covered behaviors:

- Smith::Tool responds to capture_result

### `spec/smith/tools/runtime_spec.rb`

Covered behaviors:

- Tool with capture_result block appends { tool:, captured: } to active collector
- Tool without capture_result does not append to collector
- Capture block that raises is logged and does not fail tool execution
- No collector active (outside workflow) — capture silently skipped
- Strict capture fails when the collector is absent
- Strict capture fails when the capture block or collector raises
- Strict capture fails when the capture block returns nil
- Strict capture preflights collector presence before perform
- Strict capture rejects a non-callable collector before host hooks or perform
- Collector nil/false return values are accepted; raising rejects delivery
- A subclass inherits its parent's capture, strictness included, until it declares its own (0.13.0; before, capture was opt-in per concrete subclass)
- Opaque host invocation context is nested, restored, and exception safe
- Incomplete scoped context is rejected before any current value is mutated

### `spec/smith/tools/chat_execution_context_spec.rb`

Covered behaviors:

- Opaque invocation context and strict collectors propagate through concurrent
  tool calls on a Smith-scoped chat
- Tools attached after Smith creates a chat receive the same scoped context
- Strict capture uncertainty takes precedence over concurrent sibling errors
- Concurrent batches on one chat isolate capture failures from one another
- Process-fatal sibling failures are not replaced by strict capture uncertainty,
  regardless of sibling completion order
- A callback-level process-fatal exception escaping the concurrent executor is
  not replaced by queued strict-capture uncertainty
- Reused chats capture invocation context per execution and cannot retain an
  earlier execution's context
- Smith fails closed when a RubyLLM chat lacks the required tool execution hook
- Raw RubyLLM chat instances remain unmodified

### `spec/smith/tools/execution_authority_spec.rb`

Covered behaviors:

- one execution authority is bound to the exact Smith tool object and exact
  admitted dispatch claim
- an authority can be consumed only once and rejects substituted claims
- nested authority scopes restore their enclosing scope safely
- the authority implementation is a private Smith tool constant

### `spec/smith/tools/execution_batch_collection_spec.rb`

Covered behaviors:

- provider membership is owned before call protocol readers can influence the
  caller-owned collection
- collection protocol checks use native Ruby operations

### `spec/smith/tools/execution_batch_source_call_spec.rb`

Covered behaviors:

- String transport metadata is owned and normalized to bounded UTF-8
- encoded Symbol names canonicalize to the registered executable Symbol
- invalid or oversized raw metadata fails before host admission or transcoding

### `spec/smith/workflow/failure_record_text_spec.rb`

Covered behaviors:

- persisted failure text is an owned, frozen, bounded UTF-8 copy
- US-ASCII text and a Symbol's name are taken as the UTF-8 text they are, the caller's String left as it was
- hostile String subclasses cannot replace native encoding, size, or copy checks
- non-UTF-8 and oversized persisted text fails closed, US-ASCII text with bytes outside it and binary text included

### `spec/smith/agent/persisted_chat_execution_context_spec.rb`

Covered behaviors:

- Persisted chat entry points `create`, `create!`, and `find` install Smith's
  per-chat tool execution boundary while returning the original record
- Real RubyLLM `acts_as_chat` records preserve instruction persistence, cached
  chat identity, message reset behavior, and tool configuration across those
  entry points without provider calls

### `spec/smith/tools/call_allowance_spec.rb`

Covered behaviors:

- Concurrent tool calls atomically admit exactly the configured allowance
- Legacy hash allowance assignment remains compatible and synchronized
- Independent legacy allowances do not serialize each other's tool execution
- Waiting-thread cancellation cannot consume an allowance slot
- Zero is a valid allowance that denies the first actual tool call
- Legacy hash-compatible `[:remaining]` reads return the current allowance
- A rejected enclosed ledger charge does not consume agent allowance
- Invalid allowance bounds fail before publication

### `spec/smith/tools/load_spec.rb`

Covered behaviors:

- `require "smith/tool_capture_failed"` loads its base error dependency directly

### `spec/smith/tools/tool_capture_failed_spec.rb`

Covered behaviors:

- persisted capture details require the exact bounded tool-name/reason schema
- malformed, duplicate, missing, future, and oversized values fail closed
- anonymous dynamic tools receive a stable bounded diagnostic name at runtime
- invalid runtime tool identities are represented by a UTF-8-safe digest label
- composite transport accepts only canonical strict-capture metadata
- legacy outcome digests cannot authenticate newly introduced capture metadata

### `spec/smith/workflow/run_result_spec.rb`

Covered behaviors:

- RunResult#tool_results returns an array
- RunResult#tool_results is a deep copy (mutation does not affect workflow state)

### `spec/smith/workflow/state_shape_spec.rb`

Covered behaviors:

- to_state keys include :tool_results
- state[:tool_results] is [] for a fresh workflow
- non-empty tool_results survive JSON round-trip and from_state restore

### `spec/smith/workflow/durability_spec.rb`

Covered behaviors:

- restored workflow captures new tool results without crashing (proves mutex recreated on restore)

### `spec/smith/workflow/parallel_spec.rb`

Covered behaviors:

- parallel branches capture tool results without loss
- strict capture uncertainty outranks retryable sibling agent failures and is
  not replayed by broad transition retry policies
- nested parallel arbitration preserves strict capture uncertainty
- root parallel arbitration preserves process-fatal failures in both completion
  orders against ordinary and strict-capture sibling failures

### `spec/smith/workflow/fanout_spec.rb`

Covered behaviors:

- heterogeneous fan-out preserves strict capture uncertainty over a retryable
  sibling agent failure without replaying the external tool outcome
- a fan-out's graph contract read for a class without `idempotency_mode` says
  `:unknown` for its idempotency mode and in-flight resume, and does not raise (Unreleased)

### `spec/smith/workflow/composite_execution_spec.rb`

Covered behaviors:

- strict capture error family, tool name, and reason survive composite JSON
  transport and reconstruct as typed branch failure evidence
- legacy non-capture error and failed branch-outcome JSON remains readable when
  optional tool metadata is absent

### `spec/smith/workflow/execution_context_spec.rb`

Covered behaviors:

- a zero-call agent budget permits model execution with no tools and denies the
  first actual tool invocation before `perform`

Notes:

- capture_result is a class-level DSL on Smith::Tool, stored as a block
- The block receives (kwargs, result) and returns a host-defined JSON-safe payload
- Captured entries are { tool: "name", captured: { ... } }
- Collector thread-local (Tool.current_tool_result_collector) is a synchronized proc wired through execution and parallel contexts
- tool_results is persisted via to_state/from_state and restored on durable resume
- Smith does not interpret captured payloads — host owns all projection
- Capture is best-effort by default: failures logged, tool execution unaffected
- Strict capture is opt-in, inherited by subclasses (0.13.0), and raises Smith::ToolCaptureFailed rather than
  permitting a checkpoint without required evidence
- Strict capture is post-result evidence, not an operation transaction; its
  failure is terminal; direct retry declarations are rejected and broad retry
  classes cannot override the classification, preventing Smith transition
  replay; side-effecting hosts still require operation receipts and
  reconciliation
- Invocation context is opaque, process-local, not persisted, and propagated to
  Smith-managed same-agent and heterogeneous parallel branches and concurrent
  tools on chats returned by Smith agent `chat`, `create`, `create!`, and `find`
  entry points. Durable workers receive context only when the host installs a
  fresh process-local scope; reused chats capture that scope per execution
- Raw RubyLLM chats and host-created threads/fibers remain host-owned and must
  install their own scope
- Agent tool-call allowance is an O(1), mutex-protected admission boundary
- Execution semantics version 3 fences persisted composite failure transport
  that preserves typed strict-capture metadata
- Collector uses a synchronized proc, not raw array mutation, for thread safety beyond MRI
- Smith normalizes envelope keys (tool, captured) but preserves host payload internals as opaque JSON-safe data
- tool_results is for compact structured evidence; large raw payloads belong in artifacts
- observed profiling behavior: handling is linear in entry count with no superlinear collector overhead under parallel append (not a hard guarantee)
- 1,000 entries and 50 parallel branches are smoke-tested without timing assertions

## Recommended Next Spec Additions

Highest-value next additions, in order:

1. Guardrail ordering and failure semantics
2. event best-effort runtime behavior
3. host-hook-installed approval denial behavior
4. context injection replacement-on-retry
5. artifact namespace isolation semantics
6. observability redaction and field-level controls
7. resume/idempotent step-boundary behavior
