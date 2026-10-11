# Testing and the Doctor

## Testing

`require "smith/testing"` runs a host's workflows in its tests without a
provider. A stubbed agent's requests are answered where they would go over
the wire, so everything above runs as for a provider's reply: the tool loop,
budget holds, the response memo, streaming, output checks and repairs, usage
entries and budgets.

```ruby
# test/test_helper.rb
require "smith/testing/minitest"   # or "smith/testing/rspec" for matchers

class NoticeTest < ActiveSupport::TestCase
  include Smith::Testing::Assertions

  test "drafts with the venue's hours, then waits for approval" do
    Smith::Testing.stub_agent(Writer, outputs: [Smith::Testing.tool_call(Lookup, venue: "the hall"),
                                                "The hall opens at 8."],
                                      usage: { input_tokens: 30, output_tokens: 6 })
    run = Notice.new(context: {})

    Smith::Testing.run_until_waiting(run)
    assert_waiting_for run, :approval
    Smith::Testing.resume_with(run, payload: { approved: true })
    assert_transitioned_through run, :draft, :approve, :publish
    assert_usage_recorded run, agent_name: Writer, stop_reason: "end_turn", input_tokens: 30
  end
end
```

- `stub_agent(agent, outputs:, usage:, stop_reason:, stream:)` answers the
  agent's requests (its class, or its registered name) with `outputs` in
  turn, the last answering every request after it: a String reply, a Hash as
  JSON text (for an output schema), or `tool_call(ToolClass, **arguments)`
  (an Array of them for one round), which runs the agent's own tools before
  its next request. A tool request naming a tool the agent does not have
  fails the call. `stop_reason: "max_tokens"` tests a truncated reply;
  `stream: n` sends a streamed step's reply in pieces of n characters. The
  stub keeps the messages each request sent (`calls`). Only the agent's own
  requests are answered, never a tool's own provider call. The chat is still
  built, so configure the provider (any key). An agent with no stub goes over
  the wire; `Smith::Testing.unstubbed = :refuse` fails its call with
  `Smith::Testing::UnstubbedCall` instead, so a mistyped stub never reaches a
  paid provider.
- `run_until_waiting(run)` runs until the run waits or ends and returns its
  wait (a durable retry's backoff is ended at once unless `retries: false`);
  `resume_with(run, payload:)` delivers the wait's event and runs on;
  `expire(run)` ends the wait as if its deadline had passed and runs on.
- A batch step's request is captured as ever (the batch queue gets it);
  `resume_with(run, payload: Smith::Testing.batch_payload(run, Smith::Testing.batch_result("text")))`
  answers it, and a fan-out's `batch_payload` takes results by branch key.
- Minitest: `assert_waiting_for(run, :event)` (or `kind: :batch`),
  `assert_transitioned_through(run, *transitions)` (in order; the steps the
  instance completed, not a failed or timed-out one),
  `assert_usage_recorded(run, count:, **usage_entry_attributes)`. RSpec:
  `be_waiting_for`, `have_transitioned_through`, `have_recorded_usage`.
- Stubs belong to the process; both helpers drop them after each test. An
  in-process `retry_on` backoff still sleeps: stub `sleep` on the workflow,
  or declare the retry `durable: true`.

## Doctor

After adding Smith, verify the integration:

```bash
# Plain Ruby
smith doctor              # offline checks
smith doctor --live       # live provider call
smith doctor --durability # persistence round-trip
smith install             # scaffold config/smith.rb

# Rails
bin/rails smith:doctor
bin/rails smith:doctor:live
bin/rails smith:doctor:durability
bin/rails generate smith:install
```

Doctor verifies: Smith loads, RubyLLM loads, minimal workflow boots, configuration is non-empty, serialization round-trips, persistence adapter works, and (with `--live`) a real provider call succeeds.
An `:active_record` persistence adapter's model is checked on every run: its
`lock_version` (Rails' locking column), a text payload, and a string key the
database keeps unique, at least 64 characters wide, read from schema
metadata (skipped when the database cannot be reached; an encrypted payload
is a warning). The durability probe writes as runs write (`store_versioned`
where the adapter has it, and `persistence_max_bytes`), so it meets what a
run would.
