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

### Host-Coordinated Message Admission

At a stable workflow boundary, a host can append one message or a bounded batch
to the persisted session history:

```ruby
workflow = ReviewWorkflow.restore("ticket:T-1042", adapter: adapter)
admission = workflow.append_session_messages!(
  role: :user,
  content: { answer: "The order id is 1042" }
)

workflow.persist!("ticket:T-1042", adapter: adapter)
```

Smith canonicalizes String and Symbol keys, owns an immutable JSON-like copy,
appends the batch under the workflow lifecycle mutex, and returns an immutable
`Smith::Workflow::MessageAdmission`. Its `message_digest` is the SHA-256 digest
of the canonical message batch and can be correlated with host-owned evidence.

Admission is bounded to 100 messages, 64 levels, 100,000 visited values, and one
MiB of canonical JSON. Integers must fit a signed 64-bit value, Floats must be
finite, Hash keys must be String or Symbol values, and cyclic or unsupported
values fail closed. Work is `O(N + sum(K log K))`, where `N` is the number of
visited values and each `K` is the key count of one Hash; retained output is
`O(N)`.

This API deliberately does not persist, resume, schedule, identify a session,
or provide idempotency. A durable host must lock its run and checkpoint, verify
the exact before identity, call admission, persist the next Smith version, and
record its own cause and before/after evidence atomically. Calling the method
while ordinary execution or a prepared split-step boundary is active is
rejected.

### Host-Coordinated Step Boundaries

Hosts can split one strict transition into explicit prepare, optional exact
dispatch claim, execution authorization, execute, and checkpoint phases:

```ruby
def execute_one_step(workflow, key, adapter)
  transition_name = nil

  ApplicationRecord.transaction do
    transition_name = workflow.prepare_persisted_step!(key, adapter: adapter)
    next unless transition_name

    prepared = workflow.prepared_persisted_step
    HostEvent.create!(
      name: "step.started",
      transition: transition_name,
      operation_token: prepared.token,
      preparation_digest: prepared.preparation_digest
    )
  end

  return unless transition_name

  workflow.confirm_prepared_step!

  if workflow.class.definition_digest
    dispatch = nil
    ApplicationRecord.transaction do
      dispatch = workflow.claim_prepared_step_dispatch!
      HostAttempt.find_by!(operation_token: workflow.prepared_persisted_step.token)
        .update!(
          status: "dispatch_claimed",
          dispatch_token: dispatch.token,
          dispatch_receipt: dispatch.to_h
        )
    end
    workflow.confirm_prepared_step_dispatch!
  end

  authorization = workflow.authorize_prepared_step_execution!
  execution_started = false
  begin
    operation_token = authorization.prepared_step.token
    dispatch_token = authorization.dispatch_claim&.token
    start_status = dispatch_token ? "dispatch_claimed" : "prepared"
    changed = ApplicationRecord.transaction do
      HostAttempt.where(
        operation_token:,
        dispatch_token:,
        status: start_status
      ).update_all(status: "executing")
    end
    committed = HostAttempt.find_by(operation_token:, dispatch_token:)
    execution_started = changed == 1 && committed&.status == "executing"
    raise "host execution start did not commit exactly once" unless execution_started
  ensure
    workflow.release_prepared_step_execution!(authorization) unless execution_started
  end

  execution = workflow.execute_authorized_prepared_step!(authorization) # external work; no host transaction
  raise execution.error if execution.failed?

  step = execution.step

  ApplicationRecord.transaction do
    workflow.persist!(key, adapter: adapter)
    HostEvent.create!(name: "step.completed", transition: step.fetch(:transition))
  end

  workflow.complete_persisted_step!
end
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
After preparation, `prepared_persisted_step` returns an immutable
`Smith::Workflow::PreparedStep` descriptor containing the opaque preparation
token, transition and origin names, pinned persistence key and logical version,
next step number, and canonical preparation-payload digest. It exposes no
workflow context, messages, tool results, prompts, or provider output. The
descriptor is a host correlation witness for
the active process-local boundary, not a replacement checkpoint or authority to
reconstruct and execute a workflow. Its scalar identity remains stable through
execution and checkpointing. Use `prepared_persisted_step.to_h` when serializing
the descriptor itself. It returns `nil` before persistence
acknowledges preparation, after an ambiguous preparation outcome, when
preparation begins on an already-terminal workflow, and after committed
completion. With a transactional adapter, the
descriptor is available inside the still-open transaction so the host can write
its own correlated record atomically. The adapter's exact transaction identity
is authoritative even when a host propagates that transaction context across
fibers or executors. The descriptor is a correlation witness, not proof that the
transaction subsequently committed.
Use `Smith::Workflow::PreparedStep.deserialize` to restore a descriptor from a
Hash or bounded JSON object. The decoder rejects missing, duplicated, and
unknown attributes, and constrains persistence/step counters to positive signed
64-bit values; direct `Dry::Struct` construction is not a transport decoder.

For a workflow declaring `definition_digest`,
`claim_prepared_step_dispatch!` atomically replaces the exact `prepared`
payload with a `dispatching` payload through the adapter's `replace_exact`
capability. The logical `persistence_version` does not change during this claim.
Memory uses its monitor, Redis uses WATCH/MULTI/EXEC within the client's native
no-reconnect scope, and Active Record uses one conditional SQL update while
advancing its optimistic-lock column. The method
performs no transition, provider, or tool work,
so an Active Record host can commit its own attempt-ledger state in the same
transaction without holding that transaction across external work. After that
transaction commits, `confirm_prepared_step_dispatch!` verifies the exact
durable claim. A rolled-back claim restores the known preparation; a missing,
modified, concurrently claimed, or ambiguously acknowledged payload fails
closed. `authorize_prepared_step_execution!` then re-verifies the exact durable
claim and returns one process-local execution capability without performing
transition, provider, or tool work. A host can commit its own `executing`
attempt record after authorization and before external work. That host write
must be a conditional compare-and-set on the exact dispatch identity, and the
host must re-read committed database state after the outer transaction returns.
An in-memory record or transaction return value is not commit evidence because
Rails deliberately swallows `ActiveRecord::Rollback`. If the exact host state
does not commit, the host must call `release_prepared_step_execution!` with the
exact capability. `execute_authorized_prepared_step!` consumes it once and
returns a `PreparedStepExecutionResult`. Its `status`, `failed?`, and `error`
fields preserve transition failure independently of Smith failure routing; a
host must not treat a failure-routed workflow state as proof that external work
succeeded. The result owns an iterative, cycle-aware snapshot bounded to 128
levels, 100,000 visited values, and 4 MiB of string data. Hashes, Arrays,
Strings, finite scalar JSON-like values, String or Symbol Hash keys, and the
exact top-level `StandardError` are supported; other values fail closed. Only the exact-payload
winner may enter provider, tool, or deterministic step work. Smith snapshots
and validates a successful step result before advancing workflow state. If the
external call returns an unsupported or over-limit value, the validation error
follows the transition's normal failure route and is returned as a typed failed
result; the success destination is never committed.

The authorization rejects copying and the standard Ruby Marshal, Psych/YAML,
and JSON serialization hooks. It is bound by object identity to one workflow
instance and by process id to the issuing Ruby process, so a forked child cannot
consume inherited authority. It is not a lease, cross-process fence, or durable
attempt receipt.
While that authority is active, Smith's prepended subclass boundary dispatches
private execution methods through the Smith-owned implementations captured by
the runtime. This includes nested child workflows that inherit the same
authorization. Ordinary workflow runs remain polymorphic and continue to honor
subclass overrides; the membrane exists only for the authorized external-work
boundary.
Until the capability is consumed or released, the host must retain exclusive
authority over that workflow recovery attempt. A process crash after the host
commits `executing` is an unknown outcome for the host to reconcile; Smith does
not infer that transition work did or did not begin.

`execute_prepared_step!` remains the compatible one-call API. It internally
authorizes and consumes the step and returns the legacy step Hash. Hosts that
need a durable pre-dispatch attempt boundary should use the explicit
authorization API instead.

Active Record exact replacement is deliberately a low-level persistence write.
It does not instantiate the model, run callbacks or validations, or update
timestamp columns; the payload and locking columns must therefore be treated as
infrastructure-owned state. Values still use Active Record type casting and
serialization. This matches Rails' documented
[`update_all`](https://api.rubyonrails.org/v8.1.1/classes/ActiveRecord/Relation.html#method-i-update_all)
contract and keeps the comparison and replacement in one SQL statement.
Smith supplies byte-exact predicates for PostgreSQL, SQLite, MySQL, and Trilogy
Active Record adapters and fails closed before mutation on an unknown adapter.
The payload column must be `text` or `string`; JSON/JSONB columns normalize
representation and therefore cannot satisfy this byte-identity contract.

The claim returns an immutable `Smith::Workflow::PreparedStepDispatch` receipt
containing the prepared-step descriptor, an opaque dispatch token, and the
canonical dispatch-payload digest. Persist `receipt.to_h` with the host attempt
record. Use `PreparedStepDispatch.deserialize` for a bounded Hash/JSON transport
round-trip; direct `Dry::Struct` construction is not a transport decoder.

Preparation also takes an O(S) defensive snapshot of
mutable workflow execution state, where S is the serialized state size. This
is the necessary ownership boundary: aliases held before preparation cannot
change what the accepted transition later consumes, and public mutable-state
readers and `to_state` return defensive snapshots while the boundary is active.
The canonical correlation digest is computed before dispatch in O(S log K)
time, where K is the largest object-key count, and is bounded to 4 MiB and
100,000 JSON nodes. Larger state must use Smith artifact references instead of
an inline split-step payload.
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

#### Restart-Safe Prepared Recovery

Cross-process recovery is opt-in. The workflow class must declare a lowercase
SHA-256 `definition_digest` covering the complete executable definition:
workflow topology, deterministic code assets, effective agents, prompts,
models, tools, schemas, and guardrails. Smith validates this digest but does not
derive it from Ruby reflection. `Proc#source_location` exposes only a filename
and line, while `RubyVM::InstructionSequence` is MRI-specific,
version-sensitive, and not portable across machines or Ruby versions. See the
official [Proc documentation](https://docs.ruby-lang.org/en/master/Proc.html)
and [InstructionSequence documentation](https://ruby-doc.org/3.2/RubyVM/InstructionSequence.html).

```ruby
class GeneratedWorkflow < Smith::Workflow
  definition_digest signed_package.digest
  idempotency_mode :strict
  # states and transitions...
end


adapter = Smith::PersistenceAdapters::ActiveRecordStore.new(
  model: WorkflowState,
  identity: "primary:workflow-states"
)

descriptor = Smith::Workflow::PreparedStep.deserialize(host_receipt.fetch(:prepared_step))
decision = Smith::Workflow::PreparedStepRecovery.not_started(descriptor)
workflow = GeneratedWorkflow.recover_prepared_step(decision, adapter: adapter)
dispatch = workflow.claim_prepared_step_dispatch!
authorization = workflow.authorize_prepared_step_execution!
# Conditionally commit the exact host attempt as executing and re-read it here.
# Release the authorization unless the committed row proves that this worker
# won; otherwise consume it outside the transaction.
execution = workflow.execute_authorized_prepared_step!(authorization)

# A replacement worker may continue a committed claim only when the host's
# exclusive attempt ledger proves transition/provider/tool execution did not start.
dispatch = Smith::Workflow::PreparedStepDispatch.deserialize(host_receipt.fetch(:dispatch_receipt))
decision = Smith::Workflow::PreparedStepRecovery.not_started(dispatch)
workflow = GeneratedWorkflow.recover_prepared_step(decision, adapter: adapter)
authorization = workflow.authorize_prepared_step_execution!
execution = workflow.execute_authorized_prepared_step!(authorization)
```

The host may construct `not_started` only after acquiring exclusive recovery
authority and proving from its durable attempt ledger that provider/tool
dispatch never started. Smith does not own leases, queues, attempt records, or
that fact. Recovery performs one fetch, validates the exact canonical payload,
class name, schema, definition digest, adapter identity, transition, origin,
step number, token, key, and version, then reconstructs a guarded process-local
boundary. It refuses an open adapter transaction and never migrates an
in-progress payload. Ordinary `restore` remains fail-closed.

Restart-safe preparation additionally requires a non-expiring adapter exposing
both `replace_exact` and a stable, bounded `persistence_identity`. Configure the
same non-secret identity for every process connected to one durable storage
domain. Memory's generated identity is process-local and is suitable only for
same-process tests. Cache adapters do not provide exact CAS and are unsupported
for restart-safe prepared recovery.

Recovery authorizes a payload already marked `dispatching` only when the host
supplies the exact committed `PreparedStepDispatch` receipt and an explicit
`not_started` decision. The host may make that decision only while holding
exclusive recovery authority and after its durable attempt ledger proves that
transition/provider/tool execution never started. Without that proof, a crash
or lost acknowledgement after the exact claim has an uncertain external
outcome. Smith never rewinds or executes it on its own.

When claim and host-attempt writes share an Active Record transaction,
`claim_prepared_step_dispatch!` leaves execution unavailable until
`confirm_prepared_step_dispatch!` runs after commit. A rollback restores the
known prepared boundary and permits a new exact claim. Any other confirmation
result remains uncertain and cannot execute.

The definition digest is pinned and sealed on the class object when preparation
or recovery authority is acquired. A concurrent DSL setter either completes
before sealing and becomes the pinned identity, or raises before claim and
execution. Repeating the same digest remains idempotent. A reloaded definition
must use a new class object; recovery through that class still validates its
digest against the durable descriptor.

Exact replacement is a current-value compare-and-swap, not a historical fencing
ledger. A restart-safe workflow key must be exclusively owned by Smith's
versioned/exact persistence path. Hosts must not call unconditional `store`,
delete/recreate the key, or restore an earlier byte-identical payload while a
boundary is active. Such an out-of-band A-to-B-to-A rewrite is
information-theoretically indistinguishable from the original value without a
separate monotonic storage generation. Hosts that permit other writers must
fence them in their own durable attempt/storage ledger; Smith does not absorb
that host policy.

Redis versioned and exact CAS require a client-native reconnect-disabling
scope around WATCH/MULTI/EXEC. redis-rb 5.4 exposes `without_reconnect`, while
newer clients may expose `disable_reconnection`; Smith accepts either and
refuses CAS before WATCH when neither exists. This follows redis-rb's official
[reconnection contract](https://github.com/redis/redis-rb#reconnections) and
prevents a transaction from being replayed after connection-scoped WATCH state
has been lost.

Workflow classes are part of the execution contract once preparation begins.
Hosts must not add or prepend methods to that class until the boundary is
complete, and custom `inherited` hooks must call `super`. The same rule applies
to reachable nested workflow and captured agent classes. Smith captures and
revalidates nested transition contracts and exact agent class bindings, while a
host must not concurrently mutate those class objects. Ruby intentionally
allows open-class mutation. Smith blocks definition-digest changes after the
class is sealed, while other post-preparation class mutation remains an
unsupported host lifecycle violation rather than something Smith attempts to
sandbox.

The lifecycle row and Smith checkpoint are atomic only when the persistence
adapter participates in the same transaction and database connection domain as
the host record. `ActiveRecordStore` can provide that property when its model
uses the same database connection; it also reports transaction state so Smith
cannot confirm an uncommitted boundary. Memory, Redis, cache-backed,
cross-database, and external adapters do not participate in
`ApplicationRecord.transaction`; hosts using them must supply their own
coordination protocol and must not claim the two writes are atomic.
Custom transactional adapters should implement both `transaction_open?` and
`transaction_identity`. The identity must be stable for one open transaction or
savepoint and change for every later transaction. Smith's `ActiveRecordStore`
uses the public `current_transaction.uuid` API for this exact fence. Smith fails
before writing when an open transaction has no exact identity capability.

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
verify the exact attempted payload without replaying the write. The host must
perform that reconciliation before retrying. If the adapter still contains the
exact preparation, Smith permits one unchanged retry; any other result remains
non-retryable. Smith retains one checkpoint witness, so retry bookkeeping is
constant space rather than growing with the number of attempts.

Transition contract capture uses cycle-aware `O(V + E)` traversal, with time
and space bounded to 10,000 visits, 4 MiB of string data, and a maximum depth
of 128. Strings are represented by SHA-256 digests rather than duplicated.
Supported mutable data shapes are frozen, `Range` endpoints are traversed, and
opaque mutable objects fail closed instead of receiving a misleading shallow
signature. Callable identity is pinned for the boundary; Ruby closure state and
method bodies remain host lifecycle concerns. Smith detects contract
replacement but does not claim to sandbox Ruby's open object model. Subclass
entry points remain guarded even when a host prepends modules after class
creation, and prepared execution bypasses host `advance!` wrappers so they
cannot become transition execution authority.

## Active Record Optimistic Locking

`ActiveRecordStore` keeps two version domains deliberately separate:

- `persistence_version` inside the JSON payload is Smith's logical workflow
  version and is compared with `expected_version`.
- the host model's Active Record `locking_column` is Rails' row-level
  compare-and-swap token and detects concurrent updates between load and save.

Across every versioned adapter, a missing key can be created only with
`expected_version: 0`. A nonzero expected version against missing state raises
`PersistenceVersionConflict` with `actual: :missing`, preventing stale workflow
objects from resurrecting host-deleted state.

Legacy object-shaped payloads without `persistence_version` use version zero.
Valid JSON scalars are not workflow-state documents, and explicit null,
negative, or non-integer versions fail closed instead of being overwritten.

The default host model needs a unique key, a JSON/text payload, and Rails'
standard optimistic-locking column:

```ruby
create_table :workflow_states do |t|
  t.string :key, null: false, index: { unique: true }
  t.text :payload, null: false
  t.integer :lock_version, null: false, default: 0
  t.timestamps
end

class WorkflowState < ApplicationRecord
end

Smith.configure do |config|
  config.persistence_adapter = :active_record
  config.persistence_options = {
    model: WorkflowState,
    identity: "primary:workflow-states"
  }
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

The unique key must be enforced by the database. Before every exact write,
Smith verifies from database metadata that the configured key is the database
primary key or has its own unconditional single-column unique index. Model-only
primary-key declarations, partial indexes, and composite indexes are not
accepted. Smith uses Active Record's table-keyed schema cache; a cold check is
`O(I)` in the table's index count and never scans workflow rows. Initial
creation uses Rails' native
`create_or_find_by!` savepoint path, so a concurrent key insert does not
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
