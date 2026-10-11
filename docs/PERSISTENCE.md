# Context, Session History, and Resume

Use `Smith::Context` when you want:

- persisted workflow context keys
- observation masking over session history
- injected state summaries

Example:

```ruby
class ReviewContext < Smith::Context
  persist :ticket_id, :current_findings, :source_urls

  session_strategy :observation_masking, window: 6, preserve_seed: true

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
- optionally preserves the complete immutable `seed_messages` prefix, with its
  original roles and order, while bounding only later workflow observations
- injects a state summary message into that prepared input
- persists declared workflow context keys
- keeps one context shape everywhere. Top-level keys must be Symbols: `new`,
  and the class-level helpers that derive a persistence key from a context
  (`restore_or_initialize`, `persisted_state_exists?`,
  `restorable_billing_state?`, `run_persisted!`), raise `Smith::WorkflowError`
  for any other key, so a `persistence_key` builder sees the same context on
  every path. Every Hash key inside a value becomes the Symbol of its String
  form, at every depth, in `new`, at each deterministic write, after hooks
  that write the live context, and on restore, so a nested read such as
  `context.dig(:fields, :title)` is the same live and after a JSON round trip.
  Integer and other keys become Symbols too (`101` becomes `:"101"`, as JSON
  would make it); Hash subclasses become plain Hashes, without default procs
  or identity comparison; colliding keys, self-containing values and nesting
  deeper than 100 levels raise `Smith::WorkflowError`. Values are not
  converted: only JSON-native values (Strings, numbers, booleans, nil, Hashes,
  Arrays) read the same after a restore, while Symbols, Times and other
  objects come back as Strings. `new` holds a normalized copy of the context,
  not the caller's Hash
- persists accepted session history
- preserves chosen next transitions across persistence
- supports JSON host round-trips through `to_state` and `.from_state`
- refuses to restore a payload whose state, or whose pending transition, the
  workflow class does not know (a deploy renamed or removed it, or the payload
  has no state while the class has an initial state), raising
  `Smith::UnknownStateOnRestore` or `Smith::UnknownTransitionOnRestore`
  instead of restoring a run that would read as terminal. A state is known
  when it is declared with `state` or `initial_state`, or named by any
  transition's `from:` or `to:`, matched by its String form, so String-named
  states restore as the Strings the class declares. The check runs after
  `migrate_from` and after the `definition_digest` check, so a digest
  mismatch is reported as one and a migration can map an old name: bump
  `persistence_schema_version` and declare `migrate_from(<previous version>)`,
  since migrations run only when the stored version is behind. Finished runs
  are refused too, by `restore`, `restore_or_initialize`,
  `restorable_billing_state?` and the class-level `run_persisted!`: to read the
  outcome of a finished run whose terminal state was renamed, migrate it or
  read the stored JSON directly. `stuck_for?` reports a stored run in an
  unknown state as stuck, since it can neither advance nor restore

`preserve_seed: true` is intended for workflows whose seed is durable external
conversation and whose later accepted outputs are internal stage handoffs. Smith
persists and validates the exact seed-prefix length, so restart does not infer
the boundary from message content. The masking pass is linear in session length
and retains only the seed prefix, injected system messages, and the configured
observation tail. Legacy state without `seed_message_count` restores with no
preserved prefix.

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

A host-admitted message cannot have the system role: only Smith (its injected
state) and the host's `seed_messages` builder put system messages in a session.
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

Persisted workflow failures use an explicit reconstruction registry. Smith does
not resolve arbitrary class names from persisted data or invoke their
constructors. Known retry-forbidden families retain their non-retryable
semantics even when the original class is no longer available; unknown classes
restore as `RuntimeError`. Failure messages and details are normalized into
bounded JSON-safe evidence before persistence; invalid or oversized details are
represented by an explicit omission marker. Inconsistent persisted class,
family, retry-policy, or known typed-detail evidence fails closed during
`from_state` as `Smith::PersistedFailureInvalid`. Failure capture uses native
Ruby class and message operations so an exception cannot override diagnostic
methods to suppress its durable terminal record. Terminal
`Smith::ToolFailureNotificationFailed` records preserve bounded diagnostic
details for both the dispatch failure and the failed host notification and
restore as the same non-retryable failure family.

Before consuming the capability, a host may inspect the exact captured agent
bindings with a block:

```ruby
authorization.each_agent_binding do |registry_name, agent_class|
  verify_host_execution_identity!(registry_name, agent_class)
end
```

This bounded enumeration performs no provider or tool work and exposes the same
classes Smith will execute. It is available only while the authorization is
active in its issuing process. Calling it after release or consumption, from a
forked process, or without a block fails closed. Smith intentionally does not
return an `Enumerator`, because deferred iteration could outlive the capability
scope. Smith first discovers binding names through a bounded graph traversal,
then resolves the complete bounded set while holding one registry monitor epoch.
Concurrent registry writes cannot split one authorization across old and new
registry states. The registry-owned bulk capture reads concrete agent bindings
without invoking lazy container callbacks, and all public registry mutation
paths share the same monitor.

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
the run as uncertain rather than blindly replaying the transition. The error's
`state` is the persisted state the interrupted step started from (a Symbol) and
its `transition` is the next transition the payload records, such as a routed
one, or nil when it records none, so the host can tell which step died without
reading Smith's payload itself. The same
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

## Step Isolation and Untrusted Content

By default a workflow keeps one transcript: each agent step sees the session
(with `inject_state` and masking applied) and its accepted output is appended
for the next step. Three declarations narrow that:

```ruby
class ReviewContext < Smith::Context
  persist :document_id, :source, :fields
  untrusted :source, :fields   # the document, and what an agent drew from it
end

class DocumentReview < Smith::Workflow
  session :isolated
  context_manager ReviewContext
  initial_state :fetched
  state :extracted

  transition :extract, from: :fetched, to: :extracted do
    execute :field_extractor,
            input: ->(ctx) { [{ role: :user, content: Smith::Untrusted.wrap(ctx[:source], source: "document") }] },
            output_to: :fields
  end
end
```

- `input:` (on `execute`, `route`, `fan_out`, `optimize` and `orchestrate`)
  is a callable of a copy of the context that returns the step's messages: a
  non-empty Array of at most 100 `{ role: :user or :assistant, content: }`
  with content, bounded and JSON-shaped like session messages (values that are
  not JSON are copied shallowly). They replace the transcript for that step;
  the agent's own instructions still apply, and Smith adds its continuation
  user turn only when they end with the output the run last added to its
  transcript, as it does for the transcript. A fan-out's branches share one
  `input:`. An optimizer's `input:` is its generator's, and also its
  evaluator's under `evaluator_context: :inject_state`, which then sees the
  input followed by the candidate and no injected state.
- `output_to: :key` writes the step's output to `key` instead of the
  transcript, once the step completes. The value is JSON-shaped (Symbols
  become Strings) and in the context's key shape, so it reads the same after a
  restore; a step with no output writes nil. An explicit `persist` list must
  allow the key: graph validation reports `:output_to_not_persisted` (and
  `:await_into_not_persisted` for an await's `into:`), and the step is refused
  before it runs. The step's output, `RunResult#output` and a later compute
  step's `last_output` are this output; the next shared agent step still reads
  the transcript, whose last output gets the continuation turn.
- `session :isolated` (per workflow; `:shared` is the default) keeps no
  transcript for agents: every agent step must declare `input:` (it fails
  otherwise, and graph validation reports `:isolated_step_without_input`),
  accepted outputs are never appended, and `inject_state` never runs. A nested
  workflow keeps its own session mode; validation warns
  (`:isolated_workflow_nests_shared_session`) when an isolated workflow nests a
  shared one.
- `untrusted :key` in a `Smith::Context` marks values from outside the system,
  and values a step derived from them: `inject_state` formatters and the
  `seed_messages` builder never receive them, and an agent that names one in
  `inputs` is refused when it runs, in this workflow and in any workflow it
  nests (runtime readiness reports `:untrusted_agent_input` and
  `:nested_untrusted_agent_input`). Reserved input names (`provider`,
  `model_id`, `endpoint_mode`) are never read from the context, so they are not
  refused. Untrustedness belongs to the key, not the value: a key that an
  agent writes from untrusted content (`output_to: :fields` above) carries the
  outside text's influence, so declare it untrusted too.
- `Smith::Untrusted.wrap(text, source:)` places outside text between tags with
  a boundary the text cannot guess. Inside a step the boundary derives from the
  run's namespace, the step's position, the source and the text, so a step that
  prepares its input again (a durable composite step on recovery) gets the same
  messages; elsewhere it is random. Wrapping changes the text: an untrusted tag
  in it (with spaces, invisible characters or full-width forms) becomes
  `untrusted-text`, and a line that opens with a role label (`system:`,
  `assistant:`, `user:`, `tool:`, `developer:`, `human:`, `ai:`, after any line
  break and behind spaces, invisible characters, brackets, quotes, `#`, `>`,
  `*`, `_` or `-`) gains "(quoted text)", ordinary text such as `user: alice`
  included. Markdown headings, XML-like tags and look-alike letters are left
  as they are. Wrapping marks where outside content starts and ends; it does
  not make the content safe to act on.
- A host admits session messages with the role `user`, `assistant` or `tool`
  only; system messages come from Smith (injected state) and the
  `seed_messages` builder. A restored session message, and a durable composite
  step's prepared message, must have one of those roles or `system`. A payload
  written by an earlier version may hold a system message the host admitted;
  it still reaches agents, so rebuild such sessions before relying on this.

### Content Parts

A message in a step's `input:` (and, for text, in `seed_messages`) can carry
content parts instead of a String:

```ruby
ref = Smith.artifacts.store(pdf_bytes, content_type: "application/pdf")   # inside a step
Smith::Message.user([Smith::Content.document(ref, media_type: "application/pdf", cache: true),
                     Smith::Content.text("Who signed?")])
Smith::Message.system([Smith::Content.text(house_style, cache: true)])     # in seed_messages
```

- **Parts.** `Smith::Content.text(text, cache: false)`,
  `Smith::Content.document(ref, media_type:, cache: false)` and
  `Smith::Content.image(ref, media_type:, cache: false)` build frozen,
  JSON-shaped parts: text of 1 byte to 1 MiB with more than whitespace, in
  UTF-8; a document (`application/pdf`, `text/plain`) or image (`image/png`,
  `image/jpeg`, `image/gif`, `image/webp`) as a ref from `Smith.artifacts.store`
  (letters, digits, `-`, `_` and `:` only, at most 1 KiB), never bytes, so a
  message with parts stays small in sessions, payloads and digests.
- **Messages.** `Smith::Message.user`, `.assistant` and `.system` take a String
  or 1 to 100 parts. Only a user message takes documents and images; system
  and assistant messages take text parts. `input:` takes user and assistant
  messages; `seed_messages` take text parts only, since a seed is built
  before the run can store an artifact. A message with parts carries
  `"parts" => true` beside its role and content; no agent output can carry
  it and `append_session_messages!` refuses it, so a structured output that
  looks like parts stays data and reaches providers as JSON text, and only
  content Smith builds from parts for the call passes to RubyLLM unencoded.
- **Whose artifacts.** A ref is read by the run whose step stored it, the
  workflows it nests, and its child runs: a child run (map, call or spawn) may
  read its parent's artifacts and those of the parent's nearest ancestors, up
  to 16 generations, so a document stored once reaches every item of a map. A
  run never reads an unrelated run's artifacts, nor its own children's; a
  child returns content, or the parent stores what it needs. Content parts are
  read only from a store that records which run stored each artifact
  (`stored_by?`, as every built-in store does), so a ref built from untrusted
  text cannot name another run's artifact or a file outside the store. A run
  that waits, retries durably or resumes in another process needs a shared
  store (S3 or R2, Active Record, or File on a shared disk) whose retention
  outlives it; see Artifacts.
- **Reading.** Before the first provider attempt Smith reads each document and
  image once and checks it, or fails the step with `Smith::ContentUnavailable`
  (a `WorkflowError`, never retried as a provider failure); the store's own
  errors (a timeout, `Smith::ArtifactStoreMissing`) pass on as they are, so
  `retry_on` can take a transient one. Each must be a
  non-empty String whose bytes match its media type (a PDF, PNG, JPEG, GIF or
  WebP by its signature; `text/plain` as UTF-8), a document at most 24 MiB and
  an image at most 5 MiB, and the request's text with its documents and images
  as they are sent (PDFs and images in base64) at most 32 MiB.
- **Anthropic** gets native blocks (`RubyLLM::Content::Raw`): a PDF or image as
  base64, a `text/plain` document as text, and `cache_control: { type:
  "ephemeral" }` on a part marked `cache: true`. A cache breakpoint caches the
  whole request prefix up to and including that block, in Anthropic's order:
  tools, then system (the agent's instructions, then the seed system
  messages), then the messages. So a cached seed prefix serves later calls of
  the same agent (same tools and instructions), and a cached `input:` part
  caches the agent's tools and instructions with it. Anthropic needs a minimum
  prefix length (about 1,024 tokens on most models), keeps a cache about 5
  minutes, charges a premium to write one, and takes at most 4 breakpoints per
  request: Smith counts the chat's own (cached instructions) with its parts,
  against every Anthropic model in the step's chain, and refuses more before
  the first call. Concurrent branches (`parallel:`, `fan_out`) each write the
  cache.
- **Other providers** get the parts as one text in their order: text parts as
  they are, a `text/plain` document inline (`<file name='document-2.txt'
  mime_type='text/plain'>...</file>`), and `[attached: image-3.png]` where each
  PDF or image stands, attached under that name. `cache:` adds nothing for
  them (OpenAI and Gemini cache on their own; Bedrock and OpenRouter get no
  cache markers from Smith). Each attempt builds its own chat, so a fallback
  model on another provider gets its own form, and a model whose provider
  takes no such content (RubyLLM raises `UnsupportedAttachmentError`) passes
  the step to the next model in the chain, or fails it with
  `Smith::ContentUnavailable` when none is left.
- **Sessions.** Seed messages keep their text parts in the session, digests
  included, and reach the agent steps that read the session: a step with
  `input:` sees only its input and its agent's instructions. A restored
  session may hold parts only among its seed messages, each valid (text parts
  only), however the payload was parsed, or the restore raises
  `Smith::SerializationError`. A document is outside content by nature and
  cannot be wrapped like text; give a step that reads one an isolated session
  or a narrow `input:`.

## Waiting

`await` and `delay` steps let a run wait, durably and bounded, without anything
sleeping or polling:

```ruby
class DocumentReview < Smith::Workflow
  initial_state :requested
  state :failed

  transition :fetch_source, from: :requested, to: :fetched do
    await :source_ready, into: :source, timeout: 6 * 3600 do |step|
      reply = SourceClient.request(ref: step.read_context(:source_ref), idempotency_key: step.await_token)
      step.resolve!(reply.to_h) if reply.complete?   # finished inline: no wait
    end
    on_timeout :source_unavailable
  end
  transition :source_unavailable, from: :requested, to: :unavailable

  transition(:cool_off, from: :fetched, to: :reviewed) { delay 600 }
end
```

- `await event, into:, timeout:` waits for `event`. `into:` is the Symbol
  context key its payload is written to; an explicit `persist` list must allow
  it, which is checked before the block runs. `timeout:` is required: positive
  seconds, or a callable that receives the context and returns them. An await
  must also declare where its timeout goes, `on_timeout` or `on_failure`; one
  with neither is refused when the class is defined. `delay seconds` waits for
  the time alone and then continues to its `to:` state. Either is the
  transition's one execution body.
- The optional block runs when the step is entered, with a step object that
  reads the context (`read_context`, `context`), names the wait (`await_token`,
  the key whatever the block sends must carry), gives other keys
  (`idempotency_key`), and may finish at once with `resolve!(payload)`, which
  takes a copy of the payload. It cannot write the context. In lax mode it runs
  again if the process dies before the wait is stored, under the same token, so
  what it sends must be idempotent by that token; in strict mode the restore of
  such a run raises `Smith::StepInProgressOnRestore` instead. `retry_on`
  retries the block, never a timeout.
- Entering a wait is not a step. `advance!` returns nil, `run!`,
  `run_persisted!` and `advance_persisted!` stop with the wait stored, and the
  step count and `max_transitions` do not move; `wall_clock` is charged only
  for the time the block ran. `waiting?` and `awaiting` (a
  `Smith::Workflow::Wait` with `kind`, `event`, `token`, `transition`, `into`,
  `entered_at`, `deadline_at`, and `children`, `attempt` and `error` for the
  waits that have them; the event and key as the transition declares them)
  let the host index the wait, and `pending_transition_name` is the
  awaited transition. While a run waits, `advance!` does nothing and the run is
  never terminal, so no `clear:` policy deletes it.
- `Workflow.resume!(key, event:, token:, payload:, adapter:)` restores the run,
  checks that it awaits that event under that token, writes the payload to
  `into:` (bounded and JSON-shaped like a session message, with the context's
  key shape; it never enters the session), completes the step, and stores the
  run with the version check. It returns `:resumed`, `:failed` when the
  completion took the failure path, `:missing` when no run is stored, or
  `:stale`, changing nothing, for any other event or token.
- A reply can arrive before its wait is stored, when the block's request is
  answered at once. If the stored run stands at that await and the token is
  the one it is entering the wait with, `resume!` completes the step at once
  (in strict mode too, where the run is caught mid-step) and the process still
  entering the wait loses its next store with
  `Smith::PersistenceVersionConflict`; restoring the run shows it past the
  await. Any other delivery to a strict run caught mid-step raises
  `Smith::StepInProgressOnRestore`.
- `Workflow.expire_wait!(key, token:, now:, adapter:)` ends a wait whose
  `deadline_at` has passed at `now` (a Time or an ISO 8601 String): a `delay`
  continues to its `to:`, an `await` takes `on_timeout` (a `StepCompleted`
  whose `to` is the await's own state) or else `on_failure` with
  `Smith::WaitTimedOut`, which is never retried and restores as itself with the
  wait it names; a durable retry's wait (`kind: :retry`) ends without a step,
  and the host must then continue the run (see Durable Retry). It returns
  `:expired`, `:not_due`, `:missing` or `:stale`. The host's scheduler decides
  when to call it; Smith never wakes a run. `now:` is the host's clock: passing
  a time at or past `deadline_at` ends a wait early, as a "retry now" control
  may.
- Only one completion of a wait wins. On one instance, a completion claims the
  wait, so a delivery and an expiry racing there cannot both complete it. Across
  processes, the class methods need an adapter with `store_versioned` (Memory,
  Redis, Active Record), so the second store fails with
  `Smith::PersistenceVersionConflict`; they refuse adapters without it.
- The completion of an await, delay, map or call, by `resume!` or
  `expire_wait!`, is the step: it has the step's position, so the token matches
  the entry's, and it emits `StepCompleted` (or `StepFailed`). The end of a
  retry wait is not a step and emits nothing; the attempt that follows is. In strict mode a waiting run is a
  checkpoint, not a step in progress, and restores cleanly.
- A stored wait is checked on restore: one that is malformed, whose deadline
  precedes its entry or has no time zone, or that sits beside a pending
  transition raises `Smith::SerializationError`; one whose transition the
  class no longer declares exactly (kind, event, `into:`) or that does not
  start from the run's state raises `Smith::UnknownTransitionOnRestore`. A
  `migrate_from` that renames such things must rewrite `awaiting` too, and
  `pending_retry` for a retry wait.
- A wait that does not end within the store's persistence TTL is refused when
  it is entered, before the block runs. `stuck_for?` reports a waiting run as stuck
  only once its deadline has passed by the threshold.
- Not in 0.12: split-step persistence refuses to prepare a step that waits or
  launches runs (an `await`, `delay`, `map`, `call` or `spawn`, or a step with
  a durable retry), or any step while the run waits, and a durable retry
  cannot wait inside split-step execution. An in-process nested workflow that
  reaches a wait fails its parent's step (runtime readiness reports
  `:nested_workflow_waits`).

### Durable Retry

`retry_on ..., durable: true` waits out each backoff as a wait of the run
instead of sleeping in the worker:

```ruby
transition :charge, from: :approved, to: :charged do
  compute { |step| Payments.charge(order, idempotency_key: step.idempotency_key) }
  retry_on Payments::Timeout, attempts: 5, backoff: 60, max_delay: 3600, durable: true
  on_failure :charge_failed
end
```

- An attempt that fails in a way the policy retries, with attempts left,
  enters a wait of kind `:retry` for the transition (no event, no `into:`),
  due when the backoff ends, under a token of the attempt it waits for. The
  step does not complete or count, and the run records its pending retry (the
  transition, the next attempt, the key generation, and the class name of the
  error) as `pending_retry`; `awaiting.attempt` and `awaiting.error` show them.
  Traces record `outcome: :retrying` (with the attempt, error and deadline)
  and, when the wait ends, `:retry_due`.
- `expire_wait!` past the deadline ends the wait without a step and returns
  `:expired`; the transition becomes the run's next. The host continues the run
  (`run_persisted!` or `advance_persisted!`), as after any wait, and the step
  makes the recorded attempt under the recorded keys: the same as the failed
  attempt's, unless that attempt was declared settled (see Replay Safety).
  It may succeed, fail for good (`on_failure`, or the error), or wait again.
  `resume!` never completes a retry wait.
- The pending retry persists until the step ends without entering a wait:
  it completes, fails, or raises. A crash during the attempt makes the same
  attempt again under the same keys in lax mode; in strict mode the attempt
  runs under the step-in-progress mark, so the restore of a run caught in it
  raises `Smith::StepInProgressOnRestore`.
- No retry wait is entered once the run's wall-clock deadline has passed, after
  a tool ran (`Smith::ToolOutcomeUncertain` is never retried), or for a backoff
  that does not end within the store's persistence TTL (the step fails with a
  `Smith::WorkflowError` whose cause is the attempt's error); runtime readiness
  reports a policy whose longest backoff, jitter included, reaches the TTL
  (`:durable_retry_outlasts_ttl`). Time spent waiting does not count toward
  `wall_clock`.
- `durable:` needs at least 2 attempts, a positive backoff and `on_failure`,
  and is refused on an await, delay, parallel, fan_out, optimize or
  orchestrate step. `on_failure` is required because a last failure raised to
  the host would leave the stored run before that attempt, as a crash does,
  so a job that runs again would make the attempt again at once, past the
  policy's attempts; through `on_failure` the failure settles the run; a map,
  call or spawn takes no `retry_on` at all. A durable retry inside an
  in-process nested workflow, or a child run that `Smith::Launchers::Inline`
  runs, fails the parent's step (a nested workflow's with the child's error as
  the cause), and runtime readiness reports it as `:nested_workflow_waits`.
  Graph inspection shows `durable: true` in the retry policy.
- A streamed step's sink (`stream:`) gets `reset(:retry_wait)` when the run
  enters a retry wait, and holds nothing durable: the attempt the host's later
  job makes streams to a new sink from the start. In a stored run, a streamed
  step's `finish` comes once `persist!` has stored the step (a store that fails
  gives the sink `fail` with the store's error instead), so a sink never shows
  as final an output the store did not keep.
- A stored `pending_retry` is checked on restore: it must name the transition
  of the stored retry wait, or the run's next transition when the run does not
  wait, with an attempt after the first, a key generation an earlier attempt
  could reach, and an error class name; a stored retry wait needs one.
  Anything else raises `Smith::SerializationError`, except a definition
  change: a transition that no longer declares a durable retry, or now
  declares fewer attempts than the recorded one, raises
  `Smith::UnknownTransitionOnRestore`.

### Batch Waits

A step whose mode is `:batch` (`execute` or `fan_out`, README "Batch mode")
sends no request: it captures each call's request as a synchronous call would
post it, hands it to `Smith.config.batch_queue` and waits.

- The requests are queued once the step's attempt has ended without error
  (its context checks included), so a step that fails queues nothing. The
  wait is of kind `:batch` (event `:batch_result`, `children` the number of
  requests, `attempt` the step attempt), due 25 hours after entry (batches end
  within 24). Its token is a key of the step's position and attempt, and is
  the `custom_id` of an agent step's request; a fan-out branch's is
  `Smith::Batch.custom_id(token, branch_key)`. The run records its pending
  batch (`pending_batch`: transition, attempt, key generation, and the digest
  of each request by its id). On restore a malformed one, an attempt past the
  step's `retry_on attempts:`, a key generation without
  `new_idempotency_key_on`, or ids the step's branches no longer give raise
  `SerializationError`, and a wait the class no longer batches is refused
  like an unknown position.
- Enqueues are one call per request. If the queue raises after taking some
  of a wait's requests, the step fails and those entries answer no wait: a
  host submits only entries whose run waits under their `await_token`
  (`awaiting.token`), and drops the rest.
- The host resumes the run once, with every result of the wait:
  `resume!(key, event: :batch_result, token:, payload: {custom_id => result})`,
  each result as the provider's results file gives it (`succeeded` with its
  `message`, `errored`, `canceled` or `expired`). A payload that names other
  ids, or a result of an unknown shape, raises ArgumentError and leaves the
  wait for a good one. `expire_wait!` past the deadline completes the step as
  if every result were missing.
- The step runs again at its attempt and key generation, each call taking its
  result instead of going over the wire, then goes on as after a synchronous
  call; the completion is the step. The request sent is the call's: a step
  that renders another one now (a model block, instructions or input that
  changed while the run waited: a date, data read afresh) takes the result all
  the same, and the call's `:provider_call` trace says `request_changed: true`
  (`pending_batch` keeps each request's digest to tell).
  Only the batch's own attempt takes results; a succeeded result no call took
  (a fan-out branch cancelled by a sibling's failure) is recorded and charged
  as a `:failed_attempt` all the same. In strict mode a completion is stored as
  a step under way before it runs, and a run caught in one is refused as
  unfinished (`StepInProgressOnRestore`). A failed result raises
  `Smith::BatchResultFailed`, which `retry_on` retries: in process, the next
  attempt sends a new batch under a new token (or goes over the wire, if the
  mode callable says :sync); a durable retry waits its backoff first, and the
  batch its next attempt sends takes the place of its pending retry. A request
  the provider refused raises `Smith::BatchRequestInvalid`, never retried.
- Admission against the budget happens when the request is queued; nothing is
  held while the run waits. The result's usage is charged when it comes, past
  the limits if need be (`Budget::Ledger#reserve_spent!`).
- A batch step cannot wait inside split-step execution, and a batch step in
  an in-process child (a nested workflow, or a child run run inline) fails
  before anything is captured or queued (readiness: `:nested_workflow_waits`).

## Child Runs

`map`, `call` and `spawn` steps start other workflows as runs of their own.
Smith decides which runs to start and checks what comes back; the host's run
launcher starts them, and the host persists them, runs them and reports their
results. Smith never queues, polls or waits on a child.

```ruby
class QueueLauncher
  # children: Smith::ChildRun (ref, key, workflow, input, untrusted_keys,
  # artifact_namespaces, #build)
  def launch(children:, parent_key:, await_token:)
    children.each do |child|
      ChildRunJob.perform_later(key: child.key, parent_key:, await_token:, ref: child.ref,
                                workflow: child.workflow.name, input: child.input,
                                untrusted_keys: child.untrusted_keys,
                                artifact_namespaces: child.artifact_namespaces)
    end
  end
end

Smith.config.run_launcher = QueueLauncher.new
```

- A child's `ref` is the index of its item, and its `key` is the step's token
  and the ref together, unique across every child-run step of every run. Items
  come from the context (a persisted key holding an Array, or a callable of the
  context, which must give the same list on a replay), so a replayed step
  launches the same children under the same keys: the launcher must be
  idempotent on `child.key`. Only a launcher whose `inline?` is true has its
  return value taken as results (it must return them, as an Array); anything
  another launcher returns is ignored. The job side rebuilds a
  `Smith::ChildRun` from its arguments (input keys as Symbols) and calls
  `#build`, which checks the untrusted key names it gets back as Strings and
  the artifact namespaces the child may read (its parent's and the parent's
  nearest ancestors', at most 16; a job that omits them gives the child none,
  and its reads of the parent's documents fail).
- A child gets only the context `input:` returns (JSON-shaped, bounded at 1 MiB
  each and 16 MiB for a step's children together) and no session. A key the
  parent treats as untrusted that `input:` passes under the same name stays
  untrusted in the child: `ChildRun#build` constructs the child with those keys
  in force, and they persist with it (`inherited_untrusted_keys`). The mark
  goes by name: a value passed under another name, or inside another value, is
  not marked, so pass untrusted content under its own key.
- A map, call or spawn needs a persisted run (`run_persisted!` or
  `advance_persisted!`), except with a launcher that runs the children itself
  (`inline?` true, as `Smith::Launchers::Inline`): it returns their results and
  the step completes at once. A map over no items completes at once and
  launches nothing. In `idempotency_mode :strict` a map, call or spawn step
  that crashed mid-launch runs again on restore, since launching is idempotent.
- Otherwise the step waits like an `await` for the event `:children`, bounded by
  its `timeout:` and routed by `on_timeout` or `on_failure`. Once every child is
  terminal the host resumes the parent with one entry per ref,
  `Smith::ChildRun.result(ref:, run_result:)`:
  `{ ref:, status: "succeeded" | "failed", state:, output:, error: }`, where a
  child failed when it ended in its failed state or any of its steps raised.
  `state`, `output` and `error` may be left out (as nil); `state` and `error`
  are text of at most 256 bytes. Results that do not match the number of
  children the step launched (`Wait#children`) raise to the host and leave the
  run waiting. They are bounded at 4 MiB together, after the outputs a map does
  not collect are dropped, so `collect: :states` or `:none` suits a large map.
- `collect: :outputs` writes the entries to `into:` in ref order, `:states`
  drops the outputs, and `:none` writes `{ succeeded:, failed: }`. A `call`
  writes its child's output itself. With `on_item_failure: :fail` (always for
  a call) any failed child fails the step with `Smith::ChildRunsFailed`
  (failure family `child_runs_failed`, up to 20 failed refs with the counts),
  so such a step must declare `on_failure`.
- No map, call or spawn takes `retry_on`: the launcher retries launching, and
  a map's results arrive with the host's resume, outside any attempt. Each
  child is a run with its own budget; the parent's budget does not cover it.
- `Smith::Launchers::Inline` runs each child to its end under the parent's
  deadline, apart from the parent's tool evidence and attribution, and reports
  a child left waiting, or one that raised, as failed with its error.
- A `spawn` launches and completes its step; nothing comes back.
- Graph inspection shows the kind (`:map`, `:call`, `:spawn`) and the child
  workflow, bound, items, collect and failure modes. Runtime readiness walks
  the child workflow like a nested one (a child may wait: it is a run of its
  own, and may map over its own workflow) and reports `:run_launcher_missing`
  when no launcher is configured. An in-process nested workflow that reaches a
  map, call or spawn is reported (`:nested_workflow_waits`) unless the launcher
  runs children in process. An agent in a child run that reads a key the
  parent marks untrusted is a warning (`:nested_untrusted_agent_input`), not
  an error as in a nested workflow, since readiness cannot see whether
  `input:` passes that key.

## Replay Safety: Idempotency Keys

A step that is replayed, by a retry or by a restore after a crash, sends its
outside requests again. Smith gives each request a key the step can pass along,
so a receiver that honours idempotency keys can drop the repeat. Passing the key
is the step's job, and what a receiver does with it stays the host's concern:

```ruby
transition :charge, from: :approved, to: :charged do
  compute do |step|
    Payments.charge(order, idempotency_key: step.idempotency_key)
    Receipts.email(order, idempotency_key: step.idempotency_key(:receipt))
  end
  retry_on Payments::Timeout, Payments::Declined, attempts: 3,
           new_idempotency_key_on: [Payments::Declined]
end
```

- `step.idempotency_key(scope = nil)` in `compute` and `run` steps,
  `idempotency_key(scope)` inside a `Smith::Tool`'s `perform`, and
  `Smith::IdempotencyKey.current(scope = nil)` for host code called from a
  running step. Each returns 64 lowercase hex characters (a SHA-256), which
  fits receivers that cap keys at 64 characters.
- A key is unique to the run, the step's position and the scope. The position
  is the step number and transition, then any nested workflow step, parallel or
  fan-out branch (durable composite branches included), optimizer round and
  role (generator, `before_eval`, evaluator), or orchestrator round and worker
  task. A worker task is named by its content and which copy of equal tasks it
  is, so a replayed orchestrator that lists the same tasks in another order
  keeps each task's key. A transition that runs again later in the run (a loop,
  or an `on_failure` route back to it) has a new step number and so new keys.
- Use a scope to tell apart several requests of one step. A tool can run several
  times in a step, and a replayed model may word or order its calls
  differently, so a tool's scope is required and should be the request's stable
  identity (`idempotency_key(customer_id:, invoice_number:)`), not free text. A
  tool's key also includes its `name`, so renaming a tool class changes its
  keys; a tool without a name is refused. A plain RubyLLM tool has only
  `Smith::IdempotencyKey.current`, so it should put its own name in the scope.
- A scope is built from Strings, Symbols, numbers, `true`, `false`, `nil`,
  Arrays and Hashes with String or Symbol keys. Symbols count as their Strings,
  Hash order does not matter, and a Float with a whole value counts as the
  Integer (a model's JSON may send `12` or `12.0`). NaN, Infinity and other
  objects raise `ArgumentError`, as do scopes nested deeper than 32 levels or
  holding more than 100,000 values, which bounds the work per key.
- Keys exist only while a step does its own work: its body, agents, tools and
  guardrails. Event handlers and `on_step` callbacks get none. The position is
  thread-local state that Smith carries into its own branch threads and
  concurrent tool calls; code in a Fiber or Thread the host creates has none,
  while `step.idempotency_key` works anywhere.
- The run part is the workflow's execution namespace, a UUID assigned when the
  workflow is built and persisted with it. A payload written without one (by an
  earlier version) gets one derived from its class, persistence key and
  creation time, the same on every restore, until a checkpoint stores it. A
  stored namespace that is not a UUID raises `Smith::SerializationError`. Runs
  built with `new` never share keys, even when one reuses another's persistence
  key after it was cleared; runs restored from copies of one payload share
  them, and their artifact scope, so a payload must not be cloned into several
  runs.
- A replay keeps a step's keys when the checkpoint written before the step
  holds the namespace and step count, as `advance_persisted!` and
  `run_persisted!` write it. In `idempotency_mode :lax` a run restored after a
  crash mid-step replays that step under its keys. In `:strict` mode the restore
  raises `Smith::StepInProgressOnRestore` instead, and reconciling the step's
  requests is the host's; a host-coordinated prepared step is never executed
  again after dispatch. A run that is never persisted has no replay to protect.

Every attempt of a step uses the same keys. A retry after an uncertain failure
(a timeout, a dropped connection) then cannot repeat a request that took
effect. Some receivers store a failed reply under its key and return it for
every repeat. When an attempt fails in a way that shows its own requests took
no effect, the attempts after it can use new keys:

- `step.fail!("declined", retryable: true, new_idempotency_key: true)` in a
  `compute` or `run` step with `retry_on`. It counts only for the step that
  raised it: a nested workflow's step that raises it does not move the parent's
  retry to new keys, because the child's earlier steps may have taken effect.
  The flag is not kept in the persisted failure record.
- `retry_on ..., new_idempotency_key_on: [Payments::Declined]`. The listed
  classes must be ones the policy retries (any class, when the policy lists none
  and Smith's retry classification decides), each listed once. Classes that may
  hide a tool's outcome are refused, and so is the option on a nested workflow,
  parallel, fan-out, optimize or orchestrate transition, where one error cannot
  speak for every request of the attempt. A broad class (`StandardError`) moves
  every retry, timeouts included, to new keys. Graph inspection shows the list
  in the transition's retry policy.

`step.attempt` is the attempt under way within one run of the step's
`retry_on` attempts, from 1 (a nested workflow's step counts its own). A host
that wants a different key on every attempt can pass it in the scope
(`step.idempotency_key([:charge, step.attempt])`).

The generation of keys lives only within one run of the step's retries (a
durable retry persists it across its waits; see Durable Retry). When
the attempts run out and the host retries the run later (a job that runs again),
the step starts again from its first keys, so a receiver that stored a failed
reply returns it again. A host that wants its own later retries to use new keys
puts a counter it owns in the scope. After a crash, the step's retries run again
from the first attempt (a durable retry's from the attempt it recorded); a replay reaches the newer keys again only if the
receivers refuse the replayed requests as they did before, which a receiver that
stores replies under their keys does.

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

Configure a store. Like workflow state, artifacts must outlive the process
that stored them whenever a run waits, retries or resumes elsewhere, so Smith
assumes none: outside `test_mode`, storing or reading an artifact with
nothing configured raises `Smith::ArtifactStoreMissing` (a run that keeps no
artifacts needs no store), and `smith doctor` warns. In a test environment,
set `test_mode` (an in-process store) or `artifact_store = :memory`.

```ruby
Smith.configure do |config|
  # Cloudflare R2, or any S3-compatible bucket (needs the aws-sdk-s3 gem, or client:)
  config.artifact_store = :s3
  config.artifact_options = {
    bucket: "smith-artifacts", prefix: "artifacts",
    endpoint: "https://<account>.r2.cloudflarestorage.com", region: "auto",
    access_key_id: ENV.fetch("R2_ACCESS_KEY_ID"), secret_access_key: ENV.fetch("R2_SECRET_ACCESS_KEY"),
    # Cloudflare's advice for aws-sdk-s3 1.178 and later:
    request_checksum_calculation: "when_required", response_checksum_validation: "when_required"
  }
  config.artifact_retention = 30 * 86_400
end
```

- An artifact is bytes: `store` takes a String (serialize anything else,
  for example with `JSON.generate`) and refuses other values with a
  `TypeError`.
- `:s3` keeps each artifact as one object under `prefix`, its key the ref (a
  random UUID after the store's tenant), with the run that stored it in the
  object's metadata; only keys of that shape are artifacts, so other objects
  in the bucket are never read, listed or deleted. It builds an
  `Aws::S3::Client` from the remaining options, or takes the host's as
  `client:` (not both); a Rails app already using R2 through Active Storage
  can pass that service's client. Smith does not depend on the SDK.
- `:active_record` keeps each artifact as a row through the host's model
  (`model:`, a class or its name):

  ```ruby
  create_table :smith_artifacts do |t|
    t.string :ref, null: false, index: { unique: true }
    t.binary :data, null: false, limit: 64.megabytes   # MySQL's default blob holds 64 KiB
    t.string :content_type, null: false
    t.string :execution_namespace, index: true
    t.timestamps
  end
  ```

- `:file` keeps files in a directory (`dir:`), shared only when the directory
  is; `:memory` keeps them in the process, for one process or tests (its refs
  are content hashes, so runs that store the same bytes share one, each with
  its own claim). A store object (or a class or module whose own methods
  store), or a store class built with the options, works too: it implements
  `store` and `fetch`; `stored_by?(ref, execution_namespace)` lets runs read
  only their own refs (content parts and a run's deletes require it), and
  `expired` and `delete(ref, execution_namespace: nil)` serve cleanup. Every
  built-in store implements them all.
- Any built-in store takes `namespace:`, a tenant prefix of letters, digits,
  `-` and `_` that its refs carry; a store reads no other tenant's refs, and
  with `artifact_tenant_isolation` it refuses to work without one.
  `artifact_retention` is the retention every built-in store's `expired`
  uses when none is given.
- Cleanup is the host's. `workflow.artifacts` is a run's view of the store
  (what its steps see as `Smith.artifacts`): it reads the run's refs, lists
  its expired ones (`expired(retention:)`) and deletes them (`delete(ref)`,
  only the run's own, and in Memory only the run's claim). Across runs,
  `Smith.artifact_backend.expired(retention:)` lists refs older than the
  retention and `delete(ref)` removes them. A run that waits keeps its
  artifacts for as long as it waits, so keep the retention longer than the
  longest wait, or clean up per run once it is cleared. A child run reads its
  ancestors' artifacts, so a parent's must outlive its spawned children. On
  S3, listing one run's expired refs costs a HEAD request per expired object
  under the prefix.

Why this matters:

- large payloads can move out of the inline workflow result
- refs are execution-scoped: a step stores and reads under its run's scope,
  which ends with the step, so outside a run's steps `Smith.artifacts` is the
  configured store itself; a child run reads its ancestors' refs too
- nested workflows inherit artifact scope correctly
