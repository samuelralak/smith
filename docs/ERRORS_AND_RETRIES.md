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

## Interrupting errors

Some errors say the host could not do its part, not that a step went wrong:
its database or its queue out of reach for a moment. Named as interrupting,
they stop a step where it is, as if its worker had stopped, instead of
failing it:

```ruby
Smith.config.interrupting_errors = [
  ActiveRecord::ConnectionNotEstablished,
  ActiveRecord::ConnectionFailed,
  Smith::PersistenceIOError
]
```

A step meets one when it is raised anywhere in the step (a compute block, a
tool, a tool failure handler, a guardrail, a budget ledger, a nested or
inline child run, a parallel branch) or is one of the first 15 causes of an
error that was. Smith then takes no failure route, makes no retry
(`retry_on`, durable ones included), records no failure (`last_failed_step`,
`StepFailed`; a deterministic step's trace says `outcome: :interrupted`),
notifies no tool failure handler and keeps no failed branch outcome. The
error itself, not one that wrapped it, reaches the caller of `advance!`,
`advance_persisted!`, `run!`, `run_persisted!`, or of `resume!` when the
delivery completes a batch step; among parallel branches and tools run
together it wins over every other error but a process-fatal one. The run's
stored state is as the step left it: a lax run takes the step again, under
the same idempotency keys and with the response memo's answers, when it is
next advanced; a strict run is found under way on restore
(`Smith::StepInProgressOnRestore`), as after a crash. The instance that
raised is not advanced again: restore the run.

Name only errors that mean your own systems failed. A provider's own failure
(`RubyLLM::Error`, or its HTTP client's `Faraday::Error`) is the provider's
whatever it was raised from, so naming a low-level class such as
`Errno::ECONNREFUSED` never turns a provider outage into an interruption;
name the provider's class itself for that. Smith does not count
interruptions: a step that meets one every time (a query of its own that
always times out, if `ActiveRecord::StatementTimeout` were named) is taken
again for as long as the host keeps advancing it, so the host bounds it, by
its job's retries or a count of its own. A `wall_clock` budget is charged as
after a crash: on restore, the time from the step's start, an outage
included, at most what is left.

A response memo, a trace adapter, a stream sink, an event handler, an
`on_step` callback, a `capture_result` block that is not strict, and a budget
ledger's `reconcile!` and `release!` log one they meet and go on, as they do
any error of their own. Only subclasses of StandardError can be named, never
StandardError itself. None are named by default, so every error takes its
step's route.

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
tools with their descriptions and parameters, schema, params), Anthropic's
prompt-cache markers aside: whether a part is cached never changes what the
call asks, so a host may decide it call by call, keeping the part's form (the
same text block, with or without its marker). A replay reaches the same key; a
call whose request changed since (a deployed prompt or tool, another model, a
date in the prompt) misses and is sent again, as a miss always may be.

Its record (`{"version" => 1 | 2, "messages" => [...], "complete" => true |
false}`, JSON) holds the messages the call added: the model's replies
(structured ones too) with their usage, stop reason and message id (a
stream's included), its tool calls and their results. It is stored when a
reply calling the tools its request offered comes, before they run; before
each later request, with their results; and when the call ends in the model's
reply (a call a tool halted keeps only its progress). A replayed call that
ended sends nothing: its reply is the step's (a streamed step's sink gets the
reply's text at once, not the earlier rounds'), its usage is recorded as if it
had just come, once, and its `:provider_call` trace says `memo: true`; a reply
that was cut off or refused fails the step as it did. One that had not ended
goes on from where it was kept. Kept after its tools' results, it continues
from them: kept tool results count as tools the step ran, so no retry or
fallback runs them again, and each is charged to the agent's `tool_calls`
allowance and the workflow's `tool_calls` budget as it was. Kept while its
tools ran (the step was cut inside a tool), the reply that called them is not
asked for again: its tools run again, under the same idempotency keys, and the
call goes on. Either way its live part goes on from the kept rounds (on a
budget ledger, a later round, held only when the step can pause for budget).
A call whose messages cannot be kept (an attachment, past 1 MiB) is not
stored, and is logged; a record Smith does not keep (its shape, or tool
results that do not answer the calls before them) is ignored, and an error
from `fetch` or `store` is logged by class: a memo never fails a step. Only a
record ending in a reply whose tools have not run is version 2, which a Smith
before 0.12.2 ignores (paying for that reply again and running its tools, as
it did); it reads every other record. Records for calls with tools that
0.12.1 kept are not found after the upgrade, nor these by 0.12.1, since the
digest now covers the tools' definitions. Keeping records and dropping them (a
TTL) are the host's; batch requests are not memoized, as their `custom_id`
already identifies them.
