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
- agent inheritance, DSL, and registry binding
- workflow DSL, transition metadata capture, serialization entry points, exact state shape, run-result surface, and persisted-context filtering
- workflow pattern namespaces
- artifact namespace, top-level accessor, configured-store resolution, built-in backend entry points, and named operational methods
- guardrail base DSL, attachment points, and built-in URL verifier namespace
- event bus surface, filtering, scoped subscriptions, typed event schema declaration, and subscription lifecycle behavior
- budget ledger surface
- context manager DSL, stored runtime configuration, and persisted-key serialization contract
- tool base class, policy DSL, capability metadata declaration, built-in tool namespaces, and current approval/authorization failure policy boundary
- trace adapter namespaces

Important contracts from the architecture document that are not yet directly specified:

- guardrail failure behavior
- event best-effort rescue behavior during dispatch
- parallel branch cancellation and merge behavior
- `MaxTransitionsExceeded` terminal state behavior beyond exception raising
- context injection replacement-on-retry semantics
- approval-required behavior when a host pre-dispatch hook is installed
- artifact namespace isolation semantics
- observability redaction, field-level controls, and runtime content-tracing policy

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
- It does not yet specify router confidence thresholds, parallel merge rules, or evaluator/orchestrator stop conditions.

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
  - `created_at`
  - `updated_at`
- round-trip via `.from_state`
- JSON-serializable state payload

Notes:

- This spec checks state shape and round-trip behavior only.
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
- `Smith::MaxTransitionsExceeded`
- workflow remains in its current state when max transitions are exceeded

Notes:

- This spec checks the documented result interface and exception behavior.
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

Notes:

- This spec covers persisted-key filtering only.
- It does not yet assert inject-state retry replacement or observation masking at chat runtime.

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

Notes:

- This spec does not yet assert rescued dispatch behavior because the architecture does not name a public emit API.

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

Notes:

- This spec covers stored configuration and formatter behavior only.
- It does not yet assert retry replacement, message persistence, or masking at chat runtime.

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
- It does not yet assert policy effects derived from those annotations.

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

Notes:

- This spec covers only the behavior explicitly described in the architecture.
- It does not yet assert retriable tool-guardrail failures.

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

Notes:

- This spec covers declaration surface only.
- It does not yet assert ordering, blocking semantics, or workflow-before-agent precedence at runtime.

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
- It does not yet specify trace payload shape, redaction rules, or content opt-in behavior.

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

Notes:

- This spec covers the in-memory backend only.
- It does not yet assert tenant/execution isolation.

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

- events fire only for successfully completed steps
- handlers are always rescued and cannot affect step success during dispatch
- host progress callbacks are outside Smith’s event contract
- event ordering constraints

Recommended future specs:

- extend `spec/smith/events/runtime_spec.rb` with dispatch rescue, successful-step scope, and ordering semantics

### Section 4.4 Guardrails

Currently uncovered:

- workflow-level vs agent-level guardrail attachment precedence
- input guardrails run before model/tool execution at runtime
- output guardrails run after model completion at runtime
- tool guardrail ordering at invocation time
- no async output validation leakage

Recommended future specs:

- extend `spec/smith/guardrails/contract_spec.rb` with runtime attachment precedence and blocking semantics
- extend `spec/smith/guardrails/order_spec.rb` with runtime execution ordering checks if stable seams are added

### Section 4.5 Budget Controller

Partially covered:

- ledger API is covered
- provider-timeout optimistic release semantics are not yet covered
- deadline behavior is not yet covered
- parallel branch cancellation budget cleanup is not yet covered

Recommended future specs:

- add `spec/smith/budget/runtime_spec.rb`

### Section 4.6 Context Manager

Partially covered:

- DSL is covered
- stored session strategy / persist / inject_state formatter behavior is covered
- observation masking behavior at chat runtime is not yet covered
- injected-state replacement-on-retry is not yet covered
- persisted key filtering in `to_state`/`from_state` is covered

Recommended future specs:

- extend `spec/smith/context/runtime_spec.rb` with observation-masking and retry-replacement behavior

### Section 4.7 Artifact Store

Partially covered:

- namespace and built-in backends are covered
- top-level accessor is covered
- artifact store operational interface is covered at the method-surface level:
  - `store`
  - `fetch`
  - `expired`
- in-memory store/fetch/expiry behavior is covered
- namespace-scoped content addressing is not yet covered
- retention and isolation configuration is not yet covered
- artifact handoff references are not yet covered

Recommended future specs:

- extend the current artifact specs with namespace-isolation and handoff-reference coverage

### Section 4.8 Observability

Partially covered:

- trace namespaces are covered
- top-level configuration surface for trace setup is covered
- structural trace defaults are covered
- content tracing is covered as opt-in by default
- redaction/disabling controls are not yet covered

### Section 5.1 Agent Invocation and Section 6 Tool Governance

Partially covered:

- `Smith::Agent` layering is covered
- `Smith::Tool` base contract is covered
- built-in tool namespace and tool entry points are covered
- top-level configuration surface used by artifacts/tracing is covered
- authorization-denied terminal behavior is covered
- approval-without-host-hook advisory behavior is covered

### Section 5.2 Workflow Execution

Partially covered:

- `advance!`, `run!`, and DSL are covered
- `run!` result object shape is covered at the method-surface level
- parallel branch failure behavior is not yet covered
- `MaxTransitionsExceeded` exception + current-state behavior are covered

Recommended future specs:

- `spec/smith/workflow/parallel_spec.rb`

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
- tool DSL exists
- retriable vs terminal behavior is not yet covered
- approval metadata remains advisory without host hook is covered
- host-hook-installed approval denial behavior is not yet covered

Recommended future specs:

- extend `spec/smith/tools/failure_policy_spec.rb` with host-hook-installed approval denial behavior

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
