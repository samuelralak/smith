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
