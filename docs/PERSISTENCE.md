# Context, Session History, and Resume

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

### Host-Coordinated Step Boundaries

Hosts can split one strict transition into explicit prepare, execute, and
checkpoint phases:

```ruby
transition_name = nil

ApplicationRecord.transaction do
  transition_name = workflow.prepare_persisted_step!(key, adapter: adapter)
  HostEvent.create!(name: "step.started", transition: transition_name)
end

workflow.confirm_prepared_step!
step = workflow.execute_prepared_step! # provider/tool work; no host transaction

ApplicationRecord.transaction do
  workflow.persist!(key, adapter: adapter)
  HostEvent.create!(name: "step.completed", transition: step.fetch(:transition))
end

workflow.complete_persisted_step!
```

This contract is available only to workflows using `idempotency_mode :strict`,
a versioned persistence adapter whose `store_versioned` method accepts `ttl:`,
and non-expiring workflow persistence. Smith explicitly pins `ttl: nil` for
every boundary write, so a later global configuration change cannot turn an
accepted checkpoint into expiring state.
`prepare_persisted_step!` writes the normal `step_in_progress` marker and returns
the pending transition name without consuming it. Duplicate preparation on the
same workflow object is rejected. The boundary is pinned to the exact
transition object, persistence key, and adapter instance selected during
preparation. The key is copied into an immutable string and the transition
contract is frozen. When an adapter can report an open transaction,
`confirm_prepared_step!` must verify the committed preparation before execution;
it refuses confirmation while that transaction is still open.
`execute_prepared_step!` re-verifies the exact durable preparation and permits
one execution attempt. Preparation also takes an O(S) defensive snapshot of
mutable workflow execution state, where S is the serialized state size. This
is the necessary ownership boundary: aliases held before preparation cannot
change what the accepted transition later consumes, and public mutable-state
readers and `to_state` return defensive snapshots while the boundary is active.
Subclass execution entry points remain guarded, and subclass TTL helpers cannot
override the pinned boundary policy. The
in-memory marker remains armed so any serialization
before committed completion still fails closed. Other workflow execution and
checkpoint APIs are rejected until the host checkpoints the accepted state
through `persist!`. After that transaction commits,
`complete_persisted_step!` verifies the exact checkpoint through the adapter
before clearing the marker and releasing the process-local boundary, and
likewise refuses to run while the adapter reports an open transaction.
`prepared_persisted_step?` exposes whether the one execution attempt remains
available without revealing transition internals.

Workflow classes are part of the execution contract once preparation begins.
Hosts must not add or prepend methods to that class until the boundary is
complete, and custom `inherited` hooks must call `super`. Ruby intentionally
allows open-class mutation, so Smith treats post-preparation class mutation as
an unsupported host lifecycle violation rather than attempting to sandbox it.

The lifecycle row and Smith checkpoint are atomic only when the persistence
adapter participates in the same transaction and database connection domain as
the host record. `ActiveRecordStore` can provide that property when its model
uses the same database connection; it also reports transaction state so Smith
cannot confirm an uncommitted boundary. Memory, Redis, cache-backed,
cross-database, and external adapters do not participate in
`ApplicationRecord.transaction`; hosts using them must supply their own
coordination protocol and must not claim the two writes are atomic.
Custom transactional adapters should implement `transaction_open?` so Smith can
enforce the same commit-aware confirmation rule.

If execution raises or the process dies after external work, the durable marker
remains set. A strict restore therefore fails closed with
`StepInProgressOnRestore`; the host must reconcile operation results or classify
the run as uncertain rather than blindly replaying the transition. The same
in-memory workflow object cannot retry an attempted transition. If a host
transaction rolls back after a successful `persist!`,
`complete_persisted_step!` rejects the rolled-back checkpoint. When the adapter
still contains the exact committed preparation, Smith restores that known
version and permits the same in-memory object to retry the unchanged checkpoint.
Any different or missing payload remains uncertain and non-retryable.

Ambiguous persistence acknowledgements also fail closed. If preparation may
have written before raising, the object cannot execute. If a post-step
checkpoint may have written before raising, `complete_persisted_step!` can
verify the exact attempted payload without replaying the write. Otherwise the
host may retry the unchanged checkpoint against the same key and adapter.

## Active Record Optimistic Locking

`ActiveRecordStore` keeps two version domains deliberately separate:

- `persistence_version` inside the JSON payload is Smith's logical workflow
  version and is compared with `expected_version`.
- the host model's Active Record `locking_column` is Rails' row-level
  compare-and-swap token and detects concurrent updates between load and save.

Legacy object-shaped payloads without `persistence_version` use version zero.
Valid JSON scalars are not workflow-state documents, and explicit null,
negative, or non-integer versions fail closed instead of being overwritten.

The default host model needs a unique key, a JSON/text payload, and Rails'
standard optimistic-locking column:

```ruby
create_table :workflow_states do |t|
  t.string :key, null: false, index: { unique: true }
  t.jsonb :payload, null: false
  t.integer :lock_version, null: false, default: 0
  t.timestamps
end

class WorkflowState < ApplicationRecord
end

Smith.configure do |config|
  config.persistence_adapter = :active_record
  config.persistence_options = { model: WorkflowState }
end
```

For a custom locking column, configure both the host model and adapter. Smith
validates this relationship but never mutates the host model:

```ruby
add_column :workflow_states, :workflow_revision, :integer,
  null: false,
  default: 0

class WorkflowState < ApplicationRecord
  self.locking_column = :workflow_revision
end

Smith.configure do |config|
  config.persistence_adapter = :active_record
  config.persistence_options = {
    model: WorkflowState,
    version_column: :workflow_revision
  }
end
```

The unique key must be enforced by the database. Initial creation uses Rails'
native `create_or_find_by!` savepoint path, so a concurrent key insert does not
invalidate a PostgreSQL caller transaction. A collision on another unique
constraint is not misreported as a key-version conflict.

Versioned writes are single-attempt. Smith translates known connection failures
to `PersistenceIOError`, but never replays an uncertain write below the
host-owned transaction boundary. The host must restore and reconcile persisted
state before deciding whether to retry. Keep the host model persistence-focused:
callbacks that raise after commit run after the write is permanent and therefore
create an inherently uncertain outcome.

The adapter participates in the caller's Active Record transaction and never
commits it. Hosts remain responsible for outer transaction boundaries, queue
claims, fencing, reconciliation, and recovery policy. See the
[official Rails optimistic-locking documentation](https://api.rubyonrails.org/classes/ActiveRecord/Locking/Optimistic.html).

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
