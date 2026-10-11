# Graph Inspection and Runtime Readiness

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
