# Patterns

Working examples for each Smith workflow pattern. The table in the [README](../README.md#patterns) is the quick selection rule; this file is the depth.

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

## Example 6: Heterogeneous Fan-Out

Use heterogeneous fan-out when different specialists should run concurrently and return named branch results under one workflow transition.

```ruby
class StaticReviewAgent < Smith::Agent
  register_as :static_review_agent
  model "gpt-4.1-nano"
end

class SecurityReviewAgent < Smith::Agent
  register_as :security_review_agent
  model "gpt-4.1-nano"
end

class CodeReviewWorkflow < Smith::Workflow
  initial_state :idle
  state :reviewed
  state :failed

  transition :review, from: :idle, to: :reviewed do
    fan_out branches: {
      static: :static_review_agent,
      security: :security_review_agent
    }
    on_failure :fail
  end
end
```

What you get:

- stable branch identity in the step output
- branch-specific agent budgets, guardrails, tools, and model configuration
- one shared prepared input for the transition
- one shared transition result, so downstream joins remain explicit in the workflow
- branch failures discard partial output and route through normal failure handling
- graph inspection exposes the join state, branch count, ordered branch map, and
  named branch-result output shape

Use same-agent `parallel: true` for repeated homogeneous work. Use `fan_out` when branches are different agents with different responsibilities.

## Example 7: Nested Workflows

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

## Example 8: Evaluator-Optimizer

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

## Repair And Wait Boundaries

Smith's workflow layer is intentionally bounded. A repair or wait-style loop is
executable in Smith only when Smith can validate the contract and enforce
deterministic stopping rules. This section does not restate every bounded
workflow helper; Orchestrator-Worker is a separate bounded delegation pattern.
Today that means:

| Loop kind | Executable? | Smith primitive | Boundary |
|---|---|---|---|
| Retry | Yes | `retry_on` | Local transition retry only. Durable scheduling and idempotency stay with the host. |
| Evaluator-Optimizer | Yes | `optimize` | Bounded refinement inside one transition using structured evaluator output. |
| Deterministic repair | Not native | Handwritten `compute` / `run` when exact semantics are owned by the workflow author. | No first-class repair contract, persisted repair counts, or graph-inspection metadata yet. |
| Guarded state re-entry | Not native | Handwritten `compute` / `run` may `route_to` a named transition. | No Smith-owned entry-count ledger, re-entry guard contract, or mutation policy yet. |
| Polling / wait | No | Host queue/timer plus Smith persistence helpers. | Smith must not model durable polling with sleeps, busy-waits, or `max_transitions` cycling. |

Do not hide a durable wait or unbounded repair policy inside `compute` / `run`.
Those primitives are synchronous deterministic steps inside the current workflow
runner. They are appropriate for local verification, normalization, failure
classification, explicit routing, and bounded retry-adjacent checks; they are
not a durable scheduler.

If a host or compiler wants deterministic repair, polling/wait, or guarded
state re-entry as reusable graph contracts, the contract must be added explicitly
before code generation claims executability. At minimum that future contract
needs bounded attempts, persisted state keys where appropriate, deterministic
exit behavior, graph-inspection metadata, and practical execution coverage.

## Example 9: Orchestrator-Worker

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

## Deterministic Steps

Not every workflow step needs an agent. Sometimes you need small, deterministic logic inside the graph: verification, routing, normalization, or failure classification. Smith provides two transition primitives for this: `compute` and `run`.

Both yield a constrained step object — not the full workflow — and execute synchronously with no agent call, no budget consumption, and no session message output.

### `compute` — Verification and Routing

Use `compute` for steps that check prior output and decide what happens next.

```ruby
transition :verify_research, from: :gathered, to: :verified do
  compute do |step|
    if step.tool_results.any? { |t| t[:captured]&.dig(:retryable) }
      step.fail!("research temporarily unavailable", retryable: true)
    end

    unless step.last_output
      step.write_outcome(kind: :terminal_failure, payload: { message: "no usable research output" })
      step.route_to(:finish_terminal_failure)
    end

    step.route_to(:structure)
  end

  on_failure :fail
end
```

### `run` — Normalization and Context Shaping

Use `run` for steps that transform or prepare workflow-local state.

```ruby
transition :normalize, from: :gathered, to: :prepared do
  run do |step|
    step.write_context(:normalized, step.last_output&.upcase)
    step.route_to(:structure)
  end
end
```

### Step Object API

The yielded step object exposes a narrow, read-heavy surface:

| Read | Write / Control |
|---|---|
| `step.context` | `step.write_context(key, value)` |
| `step.read_context(key)` | `step.write_outcome(kind:, payload:)` |
| `step.last_output` / `step.output` | `step.route_to(:transition_name)` |
|  | `step.fail!(msg, retryable:, kind:, details:)` |
| `step.tool_results` | |
| `step.session_messages` | |
| `step.current_state` | |
| `step.transition_name` | |

### Behavior

- **Routing**: `step.route_to` overrides `on_success`. If neither is set, normal state-based resolution applies. Named transitions that do not exist fail loudly with `WorkflowError`.
- **Failure**: `step.fail!` raises `Smith::DeterministicStepFailure` (extends `WorkflowError`) with `retryable`, `kind`, and `details` metadata. Routes through `on_failure` like any other step failure.
- **Outcome**: `step.write_outcome(kind:, payload:)` stores a workflow-owned terminal payload without smuggling it through context. The payload is persisted with the workflow and surfaced on `RunResult.outcome`, `RunResult.outcome_kind`, and `RunResult.outcome_payload`.
- **Context reads**: `step.context` returns an isolated snapshot of the workflow context at step start. Mutating that snapshot does not mutate workflow state. `step.read_context(key)` returns a merged view — pending `write_context` values override the snapshot. Use `read_context` when you need read-after-write coherence within the same step.
- **No output**: Deterministic steps produce no session message output. `last_output` continues to mean the last agent output.
- **No budget**: No tokens or cost consumed.
- **Persistence**: Context writes and written outcomes survive `to_state`/`from_state`. The block itself (a Proc) lives on the class-level Transition and is never serialized.
- **Trace**: Emits `:deterministic_step` traces for start, success/routed, and failure. When a step writes an outcome, the trace includes `outcome_kind`.
- **Mutual exclusivity**: `compute` and `run` cannot be combined with `execute`, `route`, `workflow`, `optimize`, or `orchestrate`. A transition declares exactly one primary execution body.
- **No hidden scheduler**: `compute` and `run` execute synchronously inside the current runner. Use them for bounded deterministic logic, not for durable polling or wake-up loops.
