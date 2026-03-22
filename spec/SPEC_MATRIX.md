# Smith Contract Spec Matrix

This matrix maps the current RSpec contract suite to the authoritative architecture document:

- Architecture: `/home/samuelralak/Projects/Cadence/AGENT_GEM_ARCHITECTURE.md`

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
- agent inheritance, DSL, registry binding, and fallback model-chain runtime behavior
- workflow DSL, transition metadata capture, serialization entry points, exact state shape, run-result surface, best-known execution cost aggregation, and persisted-context filtering
- workflow pattern namespaces
- artifact namespace, top-level accessor, configured-store resolution, built-in backend entry points, and named operational methods
- artifact lifecycle behavior, including opaque refs, per-store isolation, and namespace-prefixed refs
- guardrail base DSL, attachment points, and built-in URL verifier namespace
- guardrail runtime ordering, blocking, and failure-routing surface
- event bus surface, filtering, scoped subscriptions, typed event schema declaration with runtime correlation values, subscription lifecycle behavior, direct dispatch ordering/rescue semantics, and typed workflow success-only event emission surface
- budget ledger surface with denied-reservation, lower-actual reconciliation, and multi-dimension behavior
- context manager DSL, stored runtime configuration, subclass inheritance behavior, and persisted-key serialization contract
- tool base class, policy DSL, runtime execute-to-perform delegation, capability metadata declaration, built-in tool namespaces, and pre-dispatch approval/authorization failure policy boundary
- trace adapter namespaces, runtime transition/tool emission surface, and memory-adapter content policy behavior

Important contracts from the architecture document that are not yet directly specified:

- richer parallel branch merge or provider-style in-flight semantics beyond the current cooperative cancellation and failure/discard surface

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

- The architecture defines dispatch-time guarantees: synchronous inline delivery, rescued/logged handler errors, successful-step-only scope, and subscription-order dispatch.
- Current code now includes an event emission/dispatch path with subscription-order dispatch, rescued/logged handlers, and typed workflow success-only emission.
- The architecture now explicitly defines Smith's built-in event taxonomy as minimal, centered on `Smith::Events::StepCompleted`.
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
- Current code now includes agent-level `fallback_models`, lifecycle fallback chaining, attempt-aware pricing via `model_used`, and accounting of failed transient attempts when trustworthy usage metadata is present.
- Remaining future work is richer provider-aware classification or observability, not the core fallback-chain contract.

What the implementation agent needs to add:

- richer provider/deployment descriptors, attempt-history observability, or broader provider-aware classification only if the architecture is extended further

## File-to-Document Mapping

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
  - `trace_retention=`
  - `trace_tenant_isolation=`
- `trace_content` defaults to `false` (content tracing is opt-in)
- structural trace fields default to enabled:
  - `trace_transitions == true`
  - `trace_tool_calls == true`
  - `trace_token_usage == true`
  - `trace_cost == true`

Notes:

- This spec checks the documented configuration surface, structural-trace defaults, and opt-in content-tracing default.
- It does not yet assert runtime adapter behavior beyond configuration values.

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
- `.find`
- explicit registration via `.register_as`

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
- successful fallback attempts are priced against the model that actually succeeded
- failed transient attempts with known usage contribute to aggregate token and best-known cost accounting
- failed transient attempts with unknown usage remain optimistic and do not fabricate accounting
- blank fallback model entries are rejected

Notes:

- Fallback remains an agent-lifecycle helper, not a workflow-level routing primitive.
- Same-model retry is not implemented as a separate Smith loop in first phase.
- This spec covers the bounded local fallback chain, not richer provider/deployment-specific failover policy.

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
- instance/class execution surface:
  - `#advance!`
  - `#run!`
  - `#state`
  - `#to_state`
  - `.from_state`
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
- Orchestrator-worker runtime behavior is covered in `spec/smith/workflow/orchestrator_worker_spec.rb`.

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
- transition DSL rejects combining `optimize` with `execute`
- generator and evaluator rounds participate in normal serial budget reservation and reconciliation
- optimization rounds remain inside one parent workflow step

Notes:

- First-phase success requires an accepted candidate; convergence without acceptance is a bounded failure, not a best-effort success mode.
- Evaluator-optimizer remains a transition-body helper inside one workflow step; it does not introduce a second workflow runner or per-round persisted resume surface.

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
- workflow binding rejects non-class targets
- workflow binding rejects non-`Smith::Workflow` classes
- transition DSL rejects combining `workflow` with `execute`
- transition DSL rejects combining `workflow` with `route`
- nested execution keeps parent step count parent-scoped
- nested execution shares the parent budget ledger with the child
- nested execution inherits the parent wall-clock deadline
- nested execution inherits the parent artifact scope without nested re-wrapping
- nested child best-known cost and token totals roll into the parent workflow run result totals

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
- worker execution uses a Smith-owned worker execution seam while remaining inside one parent workflow step
- orchestrator-worker keeps parent step count parent-scoped
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
  - `context`
  - `budget_consumed`
  - `step_count`
  - `execution_namespace`
  - `created_at`
  - `updated_at`
  - `next_transition_name`
  - `session_messages`
  - `total_cost`
  - `total_tokens`
- round-trip via `.from_state`
- `budget_consumed` is serialized from the live ledger after execution
- `.from_state` rebuilds a live ledger with the same consumed and remaining budget
- resumed workflows continue reserving and reconciling budget from restored ledger state
- persisted `next_transition_name` preserves the selected resume path across restore
- persisted `total_cost` and `total_tokens` preserve cumulative best-known workflow totals across restore
- JSON-serializable state payload
- host-style JSON round-trip restore via `JSON.generate` / `JSON.parse` preserves executable state, selected next transition, persisted context, session history, restored budget state, and persisted cumulative totals

Notes:

- This spec now covers state shape, Ruby-hash round-trip behavior, host-style JSON round-trip behavior, and restored budget-ledger equivalence.
- It does not yet assert non-serialization of every possible Ruby object in nested structures.

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
- `total_cost` is Smith's best-known computed workflow cost subtotal
- `total_tokens` is Smith's best-known workflow token subtotal
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
- It does not yet assert richer provider-style in-flight completion behavior or provider-timeout optimistic release behavior beyond the current cooperative cancellation and failure/discard surface.

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
- `#reserve!`
- `#reconcile!`
- `#release!`
- `Smith::BudgetExceeded`

Behavior currently asserted:

- reservation checks against committed plus reserved usage
- reconciliation frees prior reservation and charges actual usage
- release frees reservation on failure/cancellation paths
- denied reservation leaves available capacity unchanged
- lower actual usage frees the unused reserved portion
- dimensions are tracked independently

Notes:

- The spec uses `Ledger.new(limits:)` to construct the ledger through the public initializer.

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
- accepted workflow output is appended to stored session history after successful step completion
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
- output guardrails run after model completion at runtime
- input and output guardrail failures route workflow execution through `on_failure`
- tool guardrail ordering at invocation time
- cooperative pre-agent-call deadline failure routing is covered
- tool-boundary retriable guardrail failure semantics are covered at the workflow boundary
- no async output validation leakage

Recommended future specs:

- `spec/smith/guardrails/runtime_spec.rb`
- extend `spec/smith/guardrails/order_spec.rb` only if additional stable seams are added

### Section 4.5 Budget Controller

Partially covered:

- ledger API is covered
- denied reservation state preservation is covered
- lower-actual reconciliation behavior is covered
- multi-dimension independence is covered
- estimate-based parallel token reservation/reconcile/release behavior is covered at the workflow boundary
- serial token reservation/reconcile/release behavior is covered at the workflow boundary
- agent `wall_clock` deadline narrowing is covered at Smith-owned call boundaries
- workflow `tool_calls` enforcement at the tool boundary is runtime-real
- agent `tool_calls` enforcement at the tool boundary is runtime-real
- agent-only `token_limit` / `cost` enforcement is covered in serial/helper-owned invocation paths
- agent-only `token_limit` / `cost` enforcement is covered in parallel invocation paths
- agent-only parallel token/cost budgets are covered as per-branch invocation constraints rather than a shared branch pool
- post-response Smith-side failure reconciliation from observed usage is covered
- persisted `budget_consumed` now reflects live ledger state
- restored workflows rebuild a live ledger and continue budget reservation/reconciliation from restored state
- provider-timeout optimistic release semantics are not yet covered

Recommended future specs:

- add `spec/smith/budget/runtime_spec.rb` only if a separate budget-focused runtime seam is introduced beyond the currently covered workflow/tool paths

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
- parallel branch count resolution, prepared-input reuse, workflow-level failure routing, discard-on-failure surface, attached tool-guardrail visibility, and estimate-based parallel token budget enforcement are covered
- serial token budget settlement and remaining-budget-based parallel estimation are covered
- cooperative pre-agent-call deadline enforcement is covered
- `MaxTransitionsExceeded` exception, current-state preservation, and non-resumable repeated/rehydrated behavior are covered

Recommended future specs:

- extend `spec/smith/workflow/parallel_spec.rb` only if richer provider-style branch semantics or provider-timeout budget behavior are added

### Section 5.3 State Serialization

Partially covered:

- entry points are covered
- exact documented hash shape is covered
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

When adding specs in these areas:

1. Re-read the architecture section first.
2. Re-check the surrounding summary tables and roadmap text.
3. Avoid encoding stronger behavior than the document claims.

## Recommended Next Spec Additions

Highest-value next additions, in order:

1. Guardrail ordering and failure semantics
2. event best-effort runtime behavior
3. host-hook-installed approval denial behavior
4. context injection replacement-on-retry
5. artifact namespace isolation semantics
6. observability redaction and field-level controls
7. resume/idempotent step-boundary behavior
