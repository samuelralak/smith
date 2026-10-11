# Errors and Retries

```ruby
Smith::Errors.retryable?(error)
# AgentError, DeadlineExceeded => true (always)
# OutputTruncated, OutputRefused, OutputInvalid (OutputFailure) => false
# DeterministicStepFailure, ToolGuardrailFailed => honors error.retryable
# everything else => false

Smith::Errors.retryable_classes
# => [Smith::AgentError, Smith::DeadlineExceeded]  (for ActiveJob retry_on)

Smith::Errors.retry_forbidden?(error)
# => true for terminal tool-evidence failures that must never be replayed
```

A nested workflow's step fails with the child's own error when the child
raises it, so these answers carry through nesting. When a tool ran inside the
child, the parent step's failure becomes `ToolOutcomeUncertain`, which is never
retried.

Workflow transitions can also declare a bounded local retry policy:

```ruby
transition :draft, from: :idle, to: :done do
  execute :writer
  retry_on Smith::AgentError, attempts: 3, backoff: 0.1, max_delay: 1.0
end
```

When no classes are passed, `retry_on` uses `Smith::Errors.retryable?`. No
attempt starts once the workflow's wall-clock deadline has passed.
This is a bounded local transition retry policy. What a receiver does with an
idempotency key remains host-owned.

For backoffs too long to sleep through in a worker, `durable: true` makes each
one a wait of the run instead:

```ruby
transition :charge, from: :approved, to: :charged do
  compute { |step| Payments.charge(order, idempotency_key: step.idempotency_key) }
  retry_on Payments::Timeout, attempts: 5, backoff: 60, max_delay: 3600, durable: true
  on_failure :charge_failed
end
```

A failed attempt the policy retries stores the run waiting (`awaiting.kind ==
:retry`, due when the backoff ends); the host schedules `expire_wait!` for that
time and then continues the run, which makes the next attempt under the step's
keys (new ones only after an attempt declared settled). See
[PERSISTENCE.md](PERSISTENCE.md), Durable Retry.

Steps and tools get idempotency keys for the requests they send outside the
system, the same on every attempt and after a restore:

```ruby
transition :charge, from: :approved, to: :charged do
  compute { |step| Payments.charge(order, idempotency_key: step.idempotency_key) }
  retry_on Payments::Timeout, Payments::Declined, attempts: 3,
           new_idempotency_key_on: [Payments::Declined]
end
```

A retry keeps the keys, so a receiver that honours them drops a request that
took effect before a timeout. An error named in `new_idempotency_key_on:` (or
`step.fail!(..., new_idempotency_key: true)`) shows the attempt's own requests
took no effect, and the attempts after it use new keys. See
[PERSISTENCE.md](PERSISTENCE.md), Replay Safety.

## Response memo

A step replayed after its process died makes its provider calls again, and
pays for them again. A host's response memo keeps what they got:

```ruby
class ResponseMemo
  def fetch(key) = Rails.cache.read("smith-memo/#{key}")
  def store(key, record) = Rails.cache.write("smith-memo/#{key}", record, expires_in: 2.days)
end

Smith.config.response_memo = ResponseMemo.new
```

Each agent call (its tool loop included) is kept under a key of its position
(the run, the step, any branch or nested position, the key generation), the
attempts it runs under (its step's, and each enclosing run's for a nested
workflow, so a retry never takes the attempt before's answer), its attempt
index (its model in the fallback chain, or a follow-up's place), its place
among the attempt's calls, and a digest of its request (model, messages,
tools, schema, params). A replay reaches the same key; a call whose request
changed since (a deployed prompt, another model, a date in the prompt) misses
and is sent again, as a miss always may be.

Its record (`{"version" => 1, "messages" => [...], "complete" => true | false}`,
JSON) holds the messages the call added: the model's replies (structured ones
too) with their usage, stop reason and message id (a stream's included), its
tool calls and their results. It is stored after each round's tool results
and when the call ends; a complete record ends with the model's reply. A
replayed call that ended sends nothing: its reply is the step's (a streamed
step's sink gets the reply's text at once, not the earlier rounds'), its usage
is recorded as if it had just come, once, and its `:provider_call` trace says
`memo: true`; a reply that was cut off or refused fails the step as it did.
One that had not ended continues from its tools' results, its live part going
on from the kept rounds (on a budget ledger, a later round). Kept tool results
count as tools the step ran, so no retry or fallback runs them again. A call
whose messages cannot be kept (an attachment, past 1 MiB) is not stored, and
is logged; a record Smith does not keep is ignored, and an error from `fetch`
or `store` is logged by class: a memo never fails a step. Keeping records and
dropping them (a TTL) are the host's; batch requests are not memoized, as
their `custom_id` already identifies them.
