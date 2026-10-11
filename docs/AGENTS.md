# Agents

How an agent's replies are checked, how its requests are shaped for each
provider, and the two other ways a step can call it: streamed, and in batch.

## Registering agents

Agents register at class load. In Rails, register workflow-facing agents in a `to_prepare` hook so autoload doesn't drop them:

```ruby
# config/initializers/smith_agents.rb
Rails.application.config.to_prepare do
  ReplyAgent
  TriageAgent
end
```

## Agent outputs

Smith reads how each response ended from the provider's stop reason. A
response cut off at its output limit, a refused one, and a structured output
that is not what the agent declares are not accepted as the step's output:

```ruby
class Reviewer < Smith::Agent
  model "claude-opus-5-5", provider: :anthropic
  output_schema ReviewSchema                         # its root is an object
  output_contract ReviewContract                     # call(hash) => true, false, or a result with success? and errors
  output_repairs 1                                   # the default; 0 turns repair off
  on_truncation retry_with: { max_tokens: 64_000 }   # or :fail (the default), or :accept
  on_refusal fallback: "openai/gpt-5"                # or :fail (the default)
end
```

- A cut-off response raises `Smith::OutputTruncated`, unless the agent
  accepts it or retries it once on the same model with a larger output limit,
  mapped to the provider's own parameter (Anthropic, OpenAI, Gemini, Vertex AI
  and Bedrock; another provider is not retried). There is no retry when the
  response ran out of context rather than output, or when the new limit is no
  larger than the request had (the agent's own parameter, or for Anthropic the
  model's maximum, which RubyLLM already sends); a later repair keeps the
  larger limit.
- A refused response (a Gemini prompt block included) raises
  `Smith::OutputRefused`, unless the agent falls back once to another model.
- Every other response then goes through the agent's `after_completion`. A
  structured output (an `output_schema`, or a static RubyLLM `schema`) that is
  not a JSON object, breaks a schema constraint, or fails the output contract
  goes back to the same model up to `output_repairs` times: the step's messages
  as the provider got them, the rejected reply as the assistant's, and the
  problems as "path: problem" lines. It then raises `Smith::OutputInvalid`,
  whose `problems` lists at most 20 of them. A blank output still raises
  `Smith::BlankAgentOutputError`.
- No follow-up call is made once a tool has run in the step (the tools would
  run again; the step fails with `Smith::ToolOutcomeUncertain` around the output
  error) or once the call has spent what its step reserved from a budget. A
  follow-up that fails raises the output error it was making up for, with the
  provider's error as its cause.
- Anthropic's structured outputs reject numeric, string-length and most
  array-size constraints: Smith sends Anthropic the schema without them, with
  `additionalProperties: false` on every object, and checks them on the parsed
  output for every provider. An object that allows other properties or
  declares none cannot be sent to Anthropic; the step fails before the call
  with a `Smith::WorkflowError`, and runtime readiness reports
  `:output_schema_unsupported` for an agent declared for Anthropic.
- An agent with no model and no fallback models fails its step with a
  `Smith::WorkflowError`; runtime readiness reports it (`:agent_without_model`).

Every response is billed and settles into budgets, whatever happens to its
output, and each rejected one leaves an `:output_rejected` trace naming its
attempt. The output errors share the failure family `output_failure`, persist
with a failed step, and are never retried by `Smith::Errors.retryable?`, a job
retry on `Smith::Errors.retryable_classes`, or a transition's
`retry_on Smith::AgentError`: Smith's own retry, fallback and repairs have run.

## Models and request shaping

Smith ships a per-attempt normalizer that translates the request payload to whatever the resolved model's provider family expects:

- Anthropic Opus 4.7+ adaptive thinking via `output_config[:effort]`
- Anthropic 4.0–4.6 budget_tokens
- OpenAI gpt-5 family reasoning_effort with `/v1/responses` routing when tools + thinking are combined
- Gemini 2.5+ budget_tokens

Override the inferred profile per-app via `Smith::Models.register(Profile.new(...))`.
Profiles are keyed by both provider and model id. Pass `provider:` to
`Smith::Models.find` or `find_or_infer` whenever an id exists under more than
one provider; an ambiguous unqualified lookup fails closed. Smith never
hardcodes model ids in the library.

Provider-qualified fallback entries use the same exact identity:

```ruby
fallback_models(
  { model: "claude-sonnet-4-6", provider: :anthropic },
  { model: "openai/gpt-5", provider: :openrouter }
)
```

Fallback entries must include an explicit provider. Smith does not infer a
fallback provider from the primary model or from a model id because the same id
may be registered by more than one provider. Unqualified fallback entries fail
closed during agent configuration.

## Streaming

An agent step can send its reply's text to the host as the model writes it:

```ruby
# Called when a streamed step starts; returns the step's sink, or nil to
# stream nothing (nobody is watching). Each step execution gets its own.
Smith.config.stream_sinks = {
  answer: ->(info) { AnswerStream.new(info[:execution_key]) if Screens.watching?(info[:execution_key]) }
}

class AnswerStream
  def initialize(key)
    @key = key
    @reply = Smith::Streaming::JsonField.new(:reply)  # the output schema's reply field, as it grows
  end

  def delta(text) = (piece = @reply.push(text)) && Screens.append(@key, piece)
  def reset(_reason) = @reply.reset || Screens.clear(@key)
  def finish(output) = Screens.final(@key, output["reply"])
  def fail(_error_class) = Screens.failed(@key)
end

class Answer < Smith::Workflow
  initial_state :asked
  state :failed

  transition :answer, from: :asked, to: :answered do
    execute :answerer, stream: :answer, output_to: :answer
    on_failure :fail
  end
end
```

A sink defines any of `start(info)` (each provider call: the step's info with
the attempt, model and provider), `delta(text)` (each text chunk; tool calls,
thinking and `<think>` text are not sent), `reset(reason)` (Smith discarded the
text sent so far: `:retry`, `:fallback`, `:truncation` or `:repair`; and
`:retry_wait`, the last word, while a durable retry waits), `finish(output)`
(the output the step accepted, after guardrails, the output contract and
`output_to:`, once the step is stored) and `fail(error_class)`. Streamed text is
a draft: guardrails and output checks run on the whole reply, so nothing should
be saved or acted on before `finish`, and a step with an output schema streams
JSON text (`Smith::Streaming::JsonField` gives the text each delta adds to one
string field). A sink that raises is logged and the step goes on; a sink name
that is not registered fails the step before its call. Stop reasons are read
from the stream, so cut-off and refused replies are handled as without it, and a
stream that ends without one counts as cut off (`stream_incomplete`). Smith's
OpenAI Responses path does not stream: its sink gets each reply as one delta.
Streaming changes nothing durable (each usage entry keeps its response's stop
reason and message id, with `mode: :stream`), and a replayed step streams again
(unless a response memo kept its reply: then its sink gets the text at once).
Graph inspection shows the stream, and runtime readiness reports a missing sink
(`:stream_sink_missing`) and an agent whose calls go to the Responses API
(`:stream_whole_replies`).

## Batch mode

An agent step, or a fan-out, can send its requests through a provider's batch
API (half price, answered within 24 hours) instead of over the wire:

```ruby
# The host keeps each request until a scheduled job submits it (a table, in
# production); enqueue is idempotent on custom_id.
class HostBatchQueue
  Entry = Struct.new(:custom_id, :await_token, :request, :run_key, :batch_id)

  def initialize = @entries = {}
  def enqueue(custom_id:, await_token:, request:, execution_key:)
    @entries[custom_id] ||= Entry.new(custom_id, await_token, request, execution_key)
  end
  def unsubmitted = @entries.values.reject(&:batch_id)
  def entry(custom_id) = @entries.fetch(custom_id)
end
Smith.config.batch_queue = HostBatchQueue.new

class Triage < Smith::Workflow
  initial_state :queued
  state :failed

  transition :triage, from: :queued, to: :triaged do
    execute :triager, mode: ->(ctx) { ctx[:urgent] ? :sync : :batch }, output_to: :verdict
    on_failure :fail
  end
end

# One scheduled job submits what is queued; another collects an ended batch
# and resumes each run once with every result of its wait.
queue = Smith.config.batch_queue
batches = Smith::Providers::Anthropic::Batches.new
entries = queue.unsubmitted
batch_id = batches.submit(entries.map { { custom_id: _1.custom_id, request: _1.request } })
entries.each { _1.batch_id = batch_id }
if batches.status(batch_id)[:status] == "ended"
  payloads = Hash.new { |hash, wait| hash[wait] = {} }
  batches.results(batch_id) do |custom_id, result|
    entry = queue.entry(custom_id)
    payloads[[entry.run_key, entry.await_token]][custom_id] = result
  end
  payloads.each { |(run_key, token), payload| Triage.resume!(run_key, event: :batch_result, token:, payload:) }
end
```

`mode:` is `:sync` (the default), `:batch`, or a callable of the context and
the step attempt returning one, on `execute` and `fan_out`; a batch step
declares `on_failure`, and cannot stream or be `parallel:`. Smith prepares
the call as a synchronous one, admits it against the budget, and hands the
exact request (the provider payload and the call's own headers, never the
connection's credentials) to the queue under a `custom_id` (the wait's token;
each fan-out branch its own) once the step's attempt has ended without error,
then the run waits on `:batch_result`. Smith never submits or polls, and waits
without sleeping: `Smith::Providers::Anthropic::Batches` gives the host
`submit`, `status`, `results` and `cancel`. `resume!` with
`{custom_id => result}` runs the step again, each call taking its result as
the reply it would have got. A call that renders another request by then (a
date in its prompt, data read afresh, a prompt changed in a deploy) does what
its step's `on_request_change:` says: `:keep` (the default) takes the result,
which answers the request as sent, and its `:provider_call` trace says
`request_changed: true`; `:resend` sends the request as rendered now over the
wire instead; `:fail` fails the step with `Smith::BatchRequestChanged` (an
`AgentError`, so `retry_on` can send it again, synchronously if the mode
callable says so). A result the call does not use is charged all the same.
Then the output checks, a follow-up call (over the
wire), guardrails and `output_to:` as ever, usage recorded with `mode: :batch`
and priced with the catalog's `batch_discount`, and charged even past a
budget, as the money is spent. A request the provider refused fails the step
(`Smith::BatchRequestInvalid`); a failed, canceled or expired result, or none
by the wait's deadline (`expire_wait!`, 25 hours), raises
`Smith::BatchResultFailed`, which `retry_on` sends again (synchronously, if the
mode callable says so at the next attempt; an in-process `retry_on` backoff
sleeps as on any step, while `durable: true` waits). Only Anthropic's batch interface is
built in, and a batch request is one turn, so a batching agent has no tools;
runtime readiness reports a missing queue (`:batch_queue_missing`) and an
agent that cannot batch (`:batch_unavailable`), and graph inspection shows the
mode.
