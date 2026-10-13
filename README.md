# Smith

Smith runs AI agents inside workflows you can trust in production. A workflow
is a state machine: each step calls an agent, runs your Ruby, routes, fans out
or waits. Every run can be saved after each step and resumed later, in another
process, so a run can wait days for a person or a webhook without holding a
worker. Smith sits on top of [RubyLLM](https://rubyllm.com), which talks to
the model providers.

What you get:

- **Workflows** with named states and transitions, which you can inspect
  before they run.
- **Durable runs**: saved after every step; they wait for events and timers,
  start child runs, and retry later. Your app owns the storage, queues and
  timers; Smith never sleeps, polls or enqueues.
- **Checked outputs**: output schemas and contracts, and handling for replies
  that are cut off, refused or malformed.
- **Cost control**: token and cost budgets per run, your own ledgers across
  runs, cache-aware pricing, and half-price batch calls.
- **Safety**: isolated steps, outside text marked untrusted, guardrails and
  tool budgets.
- **Operations**: streaming, traces, a doctor, and a testing kit.

> [!WARNING]
> Smith is pre-1.0: contracts can tighten between minor versions. Pin an exact
> version.

## Install

```ruby
# Gemfile
gem "smith-agents", "0.12.6", require: "smith"
```

In a Rails app:

```bash
bin/rails generate smith:install
bin/rails db:migrate
```

This writes `config/initializers/smith.rb` and a `WorkflowState` table where
runs are saved. (The gem is called `smith-agents` because `smith` was taken; the
Ruby namespace is `Smith`.)

## A first workflow

```ruby
require "smith"

RubyLLM.configure { |config| config.anthropic_api_key = ENV.fetch("ANTHROPIC_API_KEY") }

class Summarizer < Smith::Agent
  register_as :summarizer
  model "claude-haiku-4-5", provider: :anthropic
  instructions { "Summarize the user's text in one sentence." }
end

class Summarize < Smith::Workflow
  initial_state :idle
  state :done
  state :failed
  seed_messages { |context| [{ role: :user, content: context[:text] }] }

  transition :summarize, from: :idle, to: :done do
    execute :summarizer, output_to: :summary
    on_failure :fail
  end
end

result = Summarize.new(context: { text: "Our Q3 revenue grew 12%..." }).run!
result.state             # => :done
result.context[:summary] # => "Revenue grew 12% in Q3..."
```

An agent is a model plus instructions (and optionally an output schema, tools
and fallback models). A workflow moves from state to state through
transitions; `execute` calls an agent, and `output_to:` keeps its reply in the
run's context for later steps.

## Steps

| Step | Declared with | Does |
|---|---|---|
| Agent call | `execute :agent` | Calls one agent. `mode: :batch` sends it through the batch API; `stream:` streams its text |
| Ruby | `compute { \|step\| ... }` | Runs your code; reads and writes the context |
| Route | `route :classifier, routes: {...}` | Picks the next transition from an agent's answer |
| Fan-out | `execute :agent, parallel: true`, `fan_out branches: {...}` | Calls agents concurrently |
| Refine | `optimize generator:, evaluator:` | Drafts and critiques in bounded rounds |
| Delegate | `orchestrate orchestrator:, worker:` | Plans tasks and hands them to workers |
| Nest | `workflow OtherWorkflow` | Runs another workflow as one step |
| Wait | `await :event, into:, timeout:`, `delay seconds` | Waits for an event your app delivers, or for a time |
| Child runs | `call`, `map`, `spawn` | Starts other workflows as runs of their own |

Steps can declare `on_failure` (where a failure goes) and `retry_on`
(bounded retries). Examples of each: [`docs/PATTERNS.md`](docs/PATTERNS.md).

## Durable runs

Save a run after every step, and it can stop and pick up again anywhere. Here a
draft waits up to two days for someone to approve it:

```ruby
class Publish < Smith::Workflow
  initial_state :idle
  state :drafted
  state :approved
  state :expired
  state :done
  state :failed

  transition :draft, from: :idle, to: :drafted do
    execute :writer, output_to: :draft
    on_failure :fail
  end

  transition :approve, from: :drafted, to: :approved do
    await :approval, into: :approval, timeout: 2 * 86_400
    on_timeout :expire
  end
  transition :expire, from: :drafted, to: :expired

  transition :publish, from: :approved, to: :done do
    compute { |step| Posts.publish(step.read_context(:draft)) }
  end
end

Publish.new(context: { topic: "Release notes" }).run_persisted!("post-42") # stops at the wait

wait = Publish.restore("post-42").awaiting            # the event, a token, the deadline
Publish.resume!("post-42", event: :approval, token: wait.token, payload: { ok: true })
Publish.restore("post-42").run_persisted!("post-42")  # runs to the end
```

Your app delivers events (`resume!`), schedules the timeout
(`expire_wait!` once `deadline_at` passes), and runs the next step from a
job. Smith stores runs through an adapter (`:active_record`, `:redis`,
`:rails_cache`, `:memory` or your own) and refuses a state past
`persistence_max_bytes`. Waits, child runs, durable retries, replay safety
and storage: [`docs/PERSISTENCE.md`](docs/PERSISTENCE.md).

## Agent outputs

An agent can declare the shape of its answer and what to do when a reply goes
wrong:

```ruby
class Reviewer < Smith::Agent
  register_as :reviewer
  model "claude-opus-4-7", provider: :anthropic
  output_schema ReviewSchema                         # the reply must be this JSON object
  output_contract ReviewContract                     # and pass your own check
  on_truncation retry_with: { max_tokens: 64_000 }   # a reply cut off at its limit
  on_refusal fallback: "anthropic/claude-sonnet-4-6" # a reply the model refused
end
```

A reply that fails its schema or contract goes back to the model once with the
problems listed; one that still fails raises `Smith::OutputInvalid`. Every
reply is billed and counted, whatever happens to it.
[`docs/AGENTS.md`](docs/AGENTS.md) covers outputs, model fallbacks, how
requests are shaped per provider, streaming and batch mode.

## Retries

```ruby
transition :charge, from: :approved, to: :charged do
  compute { |step| Payments.charge(step.read_context(:order_id), idempotency_key: step.idempotency_key) }
  retry_on Payments::Timeout, attempts: 5, backoff: 60, durable: true
  on_failure :fail
end
```

`retry_on` retries a step a bounded number of times. With `durable: true` the
run waits between attempts instead of sleeping in a worker. Each step gets
idempotency keys that stay the same across retries and restores, so a
receiver can drop a request it already handled. A response memo keeps what a
step's provider calls returned, so a step replayed after a crash doesn't pay
again. Errors you name as interrupting (your database out of reach) stop a
step as a crash would, instead of failing it.
[`docs/ERRORS_AND_RETRIES.md`](docs/ERRORS_AND_RETRIES.md)

## Budgets

```ruby
class Research < Smith::Workflow
  budget total_tokens: 200_000, total_cost: 2.00, wall_clock: 300
  budget_ledger(:account_id) { |scope| AccountLedger.new(scope[:account_id]) }
  # states and transitions as usual
end
```

`budget` bounds one run. `budget_ledger` names your own ledger (an account's
monthly spend, say): Smith asks it to hold each request's estimated cost before
sending it, and settles the real cost after. A refusal stops the step before
anything is sent, and a step can wait for budget instead.
[`docs/BUDGETS.md`](docs/BUDGETS.md)

## Streaming and batch

`execute :writer, stream: :answer` sends the reply's text to a sink you
register as the model writes it. Treat it as a draft: Smith checks the reply
only once it is complete. `execute :triager, mode: :batch` sends the request
through Anthropic's batch API at half price; the run waits, and your app
delivers the result when the batch ends.
[`docs/AGENTS.md`](docs/AGENTS.md)

## Untrusted content

```ruby
class ReviewContext < Smith::Context
  persist :source, :fields
  untrusted :source, :fields
end

class DocumentReview < Smith::Workflow
  context_manager ReviewContext
  session :isolated
  initial_state :fetched
  state :extracted

  transition :extract, from: :fetched, to: :extracted do
    execute :field_extractor,
            input: ->(ctx) { [{ role: :user, content: Smith::Untrusted.wrap(ctx[:source], source: "document") }] },
            output_to: :fields
  end
end
```

With `session :isolated`, each agent step sees only the messages its `input:`
builds, not a shared transcript. Keys marked `untrusted` never reach
instructions, and `Smith::Untrusted.wrap` fences outside text off from
everything else. Messages can carry documents and images.
[`docs/PERSISTENCE.md`](docs/PERSISTENCE.md), Step Isolation.

## Tools and guardrails

Agents can use `Smith::Tool` subclasses, with a budget on how many calls a
step may make. Guardrails check inputs, outputs and tool calls. Smith ships
`Tools::Think`; `Tools::WebSearch` and `Tools::UrlFetcher` are stubs that
declare the interface, which you subclass with your own search or fetch.
[`docs/TOOLS_AND_GUARDRAILS.md`](docs/TOOLS_AND_GUARDRAILS.md)

## Testing

```ruby
require "smith/testing/minitest" # or "smith/testing/rspec"

class PublishTest < ActiveSupport::TestCase
  include Smith::Testing::Assertions

  test "drafts, then waits for approval" do
    Smith::Testing.stub_agent(Writer, outputs: "Release notes for 2.0.")
    run = Publish.new(context: { topic: "Release notes" })

    Smith::Testing.run_until_waiting(run)
    assert_waiting_for run, :approval
    Smith::Testing.resume_with(run, payload: { ok: true })
    assert_transitioned_through run, :draft, :approve, :publish
  end
end
```

A stubbed agent is answered where its request would go to the provider, so
everything else runs for real: tools, budgets, retries, output checks.
[`docs/TESTING.md`](docs/TESTING.md)

## Doctor

```bash
bin/rails smith:doctor              # configuration, models, the state table
bin/rails smith:doctor:durability   # saves and restores a run
bin/rails smith:doctor:live         # one real provider call
```

Outside Rails: `smith doctor`, `smith doctor --durability`, `smith doctor --live`.

## Documentation

| Topic | Read |
|---|---|
| Step patterns, with examples | [`docs/PATTERNS.md`](docs/PATTERNS.md) |
| Agents: outputs, models, streaming, batch | [`docs/AGENTS.md`](docs/AGENTS.md) |
| Runs: storage, waits, child runs, retries, isolation, artifacts | [`docs/PERSISTENCE.md`](docs/PERSISTENCE.md) |
| Errors, retries, the response memo | [`docs/ERRORS_AND_RETRIES.md`](docs/ERRORS_AND_RETRIES.md) |
| Budgets and ledgers | [`docs/BUDGETS.md`](docs/BUDGETS.md) |
| Tools and guardrails | [`docs/TOOLS_AND_GUARDRAILS.md`](docs/TOOLS_AND_GUARDRAILS.md) |
| Every setting | [`docs/CONFIGURATION.md`](docs/CONFIGURATION.md) |
| Testing and the doctor | [`docs/TESTING.md`](docs/TESTING.md) |
| Inspecting a workflow before it runs | [`docs/INSPECTION.md`](docs/INSPECTION.md) |
| Working on Smith itself | [`docs/DEVELOPMENT.md`](docs/DEVELOPMENT.md) |
| What changed | [`CHANGELOG.md`](CHANGELOG.md) |

## Versions

Pin an exact version. Apps that cache workflow definitions should include
`Smith::EXECUTION_SEMANTICS_VERSION` in their cache key: it changes when the
way Smith executes workflows changes, independently of the gem version.

## License

MIT.
