# Budgets and Deadlines

```ruby
class BudgetedWorkflow < Smith::Workflow
  budget total_tokens: 10_000, total_cost: 0.50, wall_clock: 30
end
```

`wall_clock` is in seconds. A workflow's `wall_clock` bounds the time its steps
spend running, counted across restores in the persisted `active_seconds`, not
the time since the run was created: time spent waiting, or between steps a host
advances from a queue, does not count. A step that raised or whose process died
is charged, on the next restore, the time from its start, at most what is left
of the budget, so a run that keeps failing stays bounded across retries.
Durable composite branches each start from what is left; their running time is
not added back. An agent's `wall_clock` bounds each of
its calls. A workflow budget accepts `total_tokens`,
`token_limit`, `total_cost`, `tool_calls`, and `wall_clock`; an agent budget
accepts `token_limit`, `cost`, `wall_clock`, `tool_calls`, `total_tokens`, and
`total_cost`. Any other key raises `ArgumentError` naming the accepted keys. A
restored run drops consumed amounts for keys the workflow no longer declares.

Budgets reserve serially at each step and reconcile after the agent call. Parallel branches reserve scoped envelopes that release back to the parent ledger. The `Workflow::RunResult` carries `total_tokens`, `total_cost`, and per-call `usage_entries`. Token budgets and totals count prompt-cache reads and writes beside uncached input and output, and settle every billed response, including the completed rounds of a tool loop whose attempt then failed.

Direct ledger integrations settle the exact receipt returned by reservation:

```ruby
reservation = ledger.reserve_many!(total_tokens: 1_000, total_cost: 0.10)
ledger.reconcile_many!(reservation, actual: { total_tokens: 640, total_cost: 0.06 })
```

`release!` / `release_many!` accept the same receipt when work never starts.
Receipts are ledger-owned and one-shot: another ledger, a replay, or an
amount-only settlement is rejected. `ledger.remaining(key)` never reads back
above the exact remaining amount, and `ledger.remaining_share(key, parts)`
returns one of `parts` equal shares of it such that reserving all `parts` fits.

Budget amounts accept finite, non-negative `Integer` and `Float` values. Smith
uses an exact `BigDecimal` representation derived from each value's canonical
decimal text and converts ledger snapshots back to ordinary JSON-safe numerics,
avoiding cumulative binary Float drift without changing persisted workflow
state shapes. Ledger arithmetic temporarily uses unlimited decimal precision and
restores the host's existing `BigDecimal` precision limit before returning.

Budget operations are atomic for normal concurrent callers and synchronous
exceptions. Smith uses cooperative cancellation and never terminates branch
threads with `Thread#raise` or `Thread#kill`. Arbitrary asynchronous thread
termination can make any in-process return value outcome-ambiguous; hosts must
use cancellation signals, bounded I/O, and process isolation for hard stops.

## Budget ledgers

A run's `budget` bounds that run. A budget shared by many runs (an account's
monthly spend, say) lives in the host, and a workflow names it with
`budget_ledger`:

```ruby
class MonthlyLedger
  def initialize(account) = @account = account

  # Admit the hold (true; anything else refuses it) and keep it under key
  # until expires_at, after which it counts for nothing.
  def reserve!(amount, key:, expires_at:) = ...
  def reconcile!(key, amount) = ...   # what the request spent, in place of its hold
  def release!(key) = ...             # it spent nothing
end

class DocumentReview < Smith::Workflow
  budget_ledger(:account_id) { |scope| MonthlyLedger.new(scope[:account_id]) }
end
```

The block gets the run's scope: the values the named keys have in its trusted
context when the run is created (JSON scalars, kept with the run), so nothing a
step or a model writes later chooses another ledger, and an untrusted key is
refused. Smith builds the ledger at the first request a step makes, never
persists it, and never needs it to restore a run; nil means none. A nested
workflow without a `budget_ledger` of its own charges the enclosing run's; a
child run (`call`, `map`, `spawn`), inline or not, uses its own class's, so
give each child workflow its own (runtime readiness warns of one that has none,
`:child_run_unbudgeted`) and pass its scope keys in each child's input.

Before a call's first request over the wire (each fallback model, each
follow-up, streamed or not, OpenAI's Responses route included) Smith asks the
ledger to admit its hold. If the ledger refuses, the step fails with
`Smith::BudgetUnavailable` (a `BudgetExceeded`, not retried by default) before
anything is sent; `retry_on Smith::BudgetUnavailable, durable: true, ...` waits
for budget instead (the host ends the wait with `expire_wait!`, and ends it
early, once there is budget, with a `now:` at its `deadline_at`). After the request, Smith reconciles what it
spent: its usage, or its hold when it answered without usage or its stream
failed part way; a request that failed before anything came back releases its
hold. If building the ledger or `reserve!` raises, the step fails with
`Smith::BudgetLedgerError` (nothing was sent, no fallback model is tried); one
from `reconcile!` or `release!` is logged by class and the step goes on, as
the money is spent.

A tool loop's later rounds continue a call whose tools already ran, so
stopping one would leave the tools' effects without their answer. A step whose
`retry_on` names `BudgetUnavailable` holds them too: when the ledger refuses
one, the loop pauses, keeping its tool calls and their results (at most 1 MiB)
with the step's retry, and the retry continues the loop from them, running
none of its tools again. Any other step's later rounds, or a loop too large to
keep, go on unheld and are reconciled with what they spent, so give tool-using
agents a `tool_calls` budget.

A hold (`Smith::Budget::Amount`: `input_tokens`, `output_tokens`, `cost`, and
`tokens`, their sum) is the request's output cap (its `max_tokens`, or its
provider's name for it, else the model's) and an estimate of its input: text
at one token per 3 bytes, an image at 1,600 tokens, a PDF at 2,000 tokens a
page, 8 tokens a message for its framing, capped at the model's context window.
Images and documents count so as RubyLLM attachments and in raw content blocks
(base64 data or a data URL). `Smith.config.budget_hold_output_tokens`, when
set, caps the output part (an agent with no `max_tokens` is otherwise held for
the model's maximum, which can be tens of thousands of tokens, and a longer
reply is reconciled at what it cost). It is priced from the pricing catalog
under the id RubyLLM resolves the model to; `cost` is nil for an unpriced
model, which runtime readiness warns of (`:budget_ledger_unpriced`, for every
agent that charges the ledger), and its readiness metrics name the scope keys.

A key is the provider attempt's `attempt_id` (as on its `:provider_call` trace)
and the request's round, `"<attempt_id>:<n>"`, and for a batch request its
`custom_id`. A batch request is held when its step captures it, at the batch
discount, and settled when its result comes: a succeeded result, used or not,
is reconciled at what it cost; one that failed, or never came, is released.
A process that dies during a request never settles its hold, so every hold
carries `expires_at`: `Smith.config.budget_hold_ttl` from now (an hour by
default; it must outlast the longest request), and for a batch request its
25-hour wait longer. Smith runs no timer; the ledger leaves holds past
`expires_at` out of what it admits, and still records a reconcile that comes
later (a batch delivered late). A key may come again after a crash (a batch
request captured again, a delivery that ran twice): a reserve of it replaces
its hold, a release ends it, and its reconcile is final, recorded once.
Fan-out branches call the ledger from their own threads. RubyLLM's own retries
(`max_retries`) resend a request under its one hold.
