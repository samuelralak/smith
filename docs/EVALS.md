# Evals

> [!WARNING]
> Experimental. `Smith::Evals` and everything under it may change in any
> release; the record formats in `docs/evals/schemas` are versioned and change
> only additively within a format version.

Evals measure a workflow on a set of examples: each example (a sample) runs a
few times (trials), each trial is scored, and the run's results come with
intervals, so "84%" reads as "84% (72% to 92%)". The run writes a record a
product can store and show, and a killed run resumes without paying again for
a trial it recorded.

Nothing loads on `require "smith"`. Load evals on their own:

```ruby
require "smith/evals"
```

That also installs the recorder into Smith's attempt seam; outside a trial it
does nothing.

## A suite

A dataset is a folder with `samples.jsonl` (one sample per line) and the
`manifest.json` that `Smith::Evals::Dataset.build_manifest` writes: the
dataset's version, its four hashes and its split into `dev`, `holdout` and
`calibration`. A suite names the dataset, the workflow under test, how a
sample becomes the workflow's context, how many trials each sample gets and
how each trial is scored:

```ruby
class TicketTriageSuite < Smith::Evals::Suite
  suite_name "support.ticket_triage"
  dataset "support_tickets"                   # under config.dataset_root
  subject workflow: TicketTriage,
          input: ->(sample) { { ticket: sample.input[:text] } },
          keep: %i[triage]                    # the end-state keys a scorer reads
  trials 3, reduce: :majority
  concurrency 2
  infrastructure_errors PG::ConnectionBad    # your own outages: errors, left out of the rate

  scorer :category, version: 1 do |sample, trial|
    Smith::Evals::Score.match(trial.state.dig(:triage, :category), sample.expected[:category])
  end
end
```

Bump a scorer's `version` when its meaning changes, and the subject's
`version:` when the input mapping does: code cannot be hashed, so these
numbers stand in for it in the suite's version.

## Running, resuming, cancelling, reading

```ruby
run = Smith::Evals.run(TicketTriageSuite,
                       scope: { tenant: "ten_0193" },               # default: config.default_scope
                       idempotency_key: "nightly-2026-11-22",       # the same key resumes or returns the run
                       started_by: Smith::Evals::Actor.service("svc_nightly_evals"))
run.status               # => :succeeded, :failed, :cancelled (or :incomplete, from slice 1b's cap)
run.result(:category)    # => a Smith::Evals::Statistics::Estimate: point, lower, upper, display, warnings
run.summary              # => the summary Hash
run.record.each_trial    # => each trial's line

Smith::Evals.cancel(run.eval_run_id, scope: { tenant: "ten_0193" },
                    actor: Smith::Evals::Actor.person("usr_51a8"), reason: "wrong dataset")
record = Smith::Evals.record("er_...", scope: { tenant: "ten_0193" })   # nil when the store has none
```

- **Order.** Trials run trial-index-major: every sample's first trial, then
  every sample's second, so a run that stops early has covered as many samples
  as it could. Up to `concurrency` trials run at once (capped by the driver's
  `max_concurrency`), each on a worker thread that carries the caller's
  attribution.
- **Retries.** A trial that ends in an error Smith retries (a provider outage,
  your own `infrastructure_errors`, the driver failing) runs again, up to
  `error_retries` times (2 by default), after `min(30, 2**attempt)` seconds,
  or at once with the driver's `retry_waits: :immediate`. The in-process
  driver waits by default, and retries at once when `smith/testing` is
  loaded, so a test suite never waits. The same setting makes it wait out a
  durable retry inside the workflow until it is due, as in production, with
  no ceiling: a step whose `retry_on` waits minutes holds its worker that
  long. Its line keeps every attempt; its latency is the last attempt's.
- **Resume.** The store is the ledger. Running the suite again with the same
  idempotency key (or `eval_run_id:`) resumes it: a trial with a line never
  runs again, so nothing recorded is paid for twice; a trial that was running
  when the process died has no line and runs again. A resume records with the
  recording bounds its header names, whatever the configuration says now. A
  finished run is returned as it is, also one another start finished while
  this one waited for the lease. Either way the suite, dataset, selection and
  trials must be those the run started with, or the start raises
  `ResumeMismatch` naming what differs.
- **Stops.** Some errors would fail every trial (no key, a refused key, no
  credit, no permission for the model, a missing model, a scope conflict, a
  workflow that cannot run, an unstubbed call in a test, the store failing):
  the first stops the run, the trials running finish and are recorded, and the
  run ends `failed`, naming the trial. A cancel ends it `cancelled`, naming
  who asked. Trials that never started count as `not_run`. A call
  interrupted while trials run (a `Timeout`, say) stops them the same way and
  raises once each has its line; the run has no summary and resumes.
- **Refusals.** A start is refused before anything is written when the suite
  or dataset is invalid, the dataset changed under its manifest, the split is
  not `dev` (holdout runs wait for slice 2), a `pass_at` or `pass_all`
  reducer's bootstrap over the samples would pass its bound (resamples times
  samples at most 100,000,000), the workflow's runtime readiness is
  `:not_ready`, or the driver does not run trials in process.

## The record

A run is four documents, kept by the store under the run's tenant scope:

| Document | Schema | What |
|---|---|---|
| `header.json` | [`record-header`](evals/schemas/record-header.schema.json) | Written once: the suite, dataset and selection, every version, the plan digest |
| `segments.jsonl` | [`segment`](evals/schemas/segment.schema.json) | One line per launch: `start`, then `resume` |
| `trials.jsonl` | [`trial`](evals/schemas/trial.schema.json) | One line per trial: its outcome, attempts, scores, usage and step records |
| `summary.json` | [`summary`](evals/schemas/summary.schema.json) | Written at the end: counts, causes, results with intervals, usage, latency |

The header's `kind` is `eval`; `try` and `online` are reserved for later
slices. Published examples, which validate against the schemas as published
and with unknown fields refused, are in [`evals/examples`](evals/examples):
three runs of a code suite (passing, failing with a kill and resume,
incomplete), the failing one after its failed trials ran again, and three
linked runs comparing models. Readers ignore fields they do not know.

**Outcomes.** `scored`, `unscored` (a scorer could not decide), `subject_failed`
(no usable answer; counts as a fail), `limit_hit` (the workflow's own limit
ran out; scored on what it had done), `error` (infrastructure; left out of
the rate) and `not_run`. Every outcome but `scored` carries a reason code and
who caused it; `summary.causes` counts the codes. A `pass_at` or `pass_all`
result reads `k` trials of a sample, so a sample with fewer counted trials
(an errored trial, a stopped run) is left out of it and counted in its
`samples_uncounted`.

**Usage.** Costs are integer nanos of `header.cost_unit`. A trial line's
`usage` is what the workflow under test spent in every attempt of the trial;
its `steps` are the last attempt's. `usage.by_model` splits it by provider and
model and adds up to it, in each line and in the summary. Every cost per
trial, per sample and per 1,000 samples is the subject's spend only, what
production would pay: grading by model judges (slice 2) is counted apart.

## Stores and drivers

`config.store` defaults to `Smith::Evals::Stores::File.new(root:
"tmp/smith-evals")`: local disk, an advisory lease per run, every write
flushed before it returns. `Smith::Evals::Stores::Memory` keeps records in
one process (tests, the worked example). A host store answers the twelve
methods of `Smith::Evals::Store`. A lease has no heartbeat, so a host store
keeps it as long as its holder lives: one that expired leases on a timer
could take a long run's lease mid-trial.

`Smith::Evals::Drivers::InProcess` (the default) runs the workflow to its end,
or to the subject's `until:` state; a workflow that waits for anything but a
retry cannot finish in one process, and its trial ends in an error,
`subject_waited`. A host driver subclasses `Smith::Evals::Driver` and wraps
each attempt with `around_trial` (a rolled-back transaction, say); the runner
writes every record outside it.

## Costs of running

The runner reads a run's lines once to resume it (`O(L)` time, `O(T)` memory
for `T` trials) and once more to write the summary; the summary's estimates
cost what `docs/DEVELOPMENT.md` lists for the statistics. A worker waits on a
condition variable, never by polling.
