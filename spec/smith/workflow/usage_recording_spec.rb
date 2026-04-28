# frozen_string_literal: true

# Locks the contract between the lifecycle's `record_usage` helper and
# the workflow's `@usage_entries` / `@total_tokens` / `@total_cost`
# state.
#
# Drives `record_usage` directly via `send(:record_usage, ...)` rather
# than mocking a full provider call — the helper's contract is the unit
# under test, not the chat plumbing. The lifecycle invokes this helper
# from two sites: `snapshot_and_finalize` (completed_attempt) and
# `account_failed_attempt` (failed_attempt). Both hit the same single-
# mutex critical section that keeps tokens + cost + entries consistent.
RSpec.describe "Smith::Workflow usage recording contract" do
  let(:workflow_class) { require_const("Smith::Workflow") }

  # Fake agent class that responds to `register_as` (the only attribute
  # `record_usage` reads). Avoids spinning up a real Smith::Agent
  # subclass with all its DSL machinery.
  let(:agent_class) do
    Class.new do
      def self.register_as = :writer_agent
    end
  end

  let(:workflow) do
    with_stubbed_class("SpecUsageRecordingWorkflow", workflow_class) do
      initial_state :idle
      state :done
      transition :go, from: :idle, to: :done
    end.new
  end

  def agent_result(input:, output:, cost:, content: "ok", model_used: "claude-opus-4-7")
    Smith::Workflow::AgentResult.new(content, input, output, cost, model_used)
  end

  describe "completed-attempt entries" do
    it "appends a :completed_attempt entry with all the agent's per-call facts" do
      result = agent_result(input: 100, output: 50, cost: 0.00175)

      workflow.send(:record_usage, agent_class, result, :completed_attempt, "claude-opus-4-7")

      entries = workflow.instance_variable_get(:@usage_entries)
      expect(entries.size).to eq(1)
      entry = entries.first
      expect(entry.usage_id).to be_a(String)
      expect(entry.usage_id).not_to be_empty
      expect(entry.agent_name).to eq(:writer_agent)
      expect(entry.model).to eq("claude-opus-4-7")
      expect(entry.input_tokens).to eq(100)
      expect(entry.output_tokens).to eq(50)
      expect(entry.cost).to eq(0.00175)
      expect(entry.attempt_kind).to eq(:completed_attempt)
      expect(entry.recorded_at).to match(/\A\d{4}-\d{2}-\d{2}T/)
    end

    it "updates @total_tokens and @total_cost in lockstep with the entry append" do
      workflow.send(:record_usage, agent_class, agent_result(input: 100, output: 50, cost: 0.00175), :completed_attempt, "claude-opus-4-7")
      workflow.send(:record_usage, agent_class, agent_result(input: 200, output: 100, cost: 0.00350), :completed_attempt, "claude-opus-4-7")

      expect(workflow.instance_variable_get(:@total_tokens)).to eq(450)
      expect(workflow.instance_variable_get(:@total_cost)).to be_within(1e-9).of(0.00525)
      expect(workflow.instance_variable_get(:@usage_entries).size).to eq(2)
    end
  end

  describe "failed-but-billable attempts" do
    it "appends a :failed_attempt entry when the provider call resolved with token usage but failed" do
      # E.g. a fallback model raised after returning input/output tokens.
      result = agent_result(input: 75, output: 0, cost: 0.0)

      workflow.send(:record_usage, agent_class, result, :failed_attempt, "claude-opus-4-6")

      entries = workflow.instance_variable_get(:@usage_entries)
      expect(entries.size).to eq(1)
      expect(entries.first.attempt_kind).to eq(:failed_attempt)
      expect(entries.first.model).to eq("claude-opus-4-6")
      expect(entries.first.input_tokens).to eq(75)
      expect(entries.first.output_tokens).to eq(0)
    end
  end

  describe "no-op when usage is unknown" do
    it "skips recording entirely when input/output tokens are nil (provider didn't report)" do
      result = Smith::Workflow::AgentResult.new("content", nil, nil, nil, "model")

      workflow.send(:record_usage, agent_class, result, :completed_attempt, "model")

      expect(workflow.instance_variable_get(:@usage_entries)).to be_empty
      # @total_tokens stays at its initialized value (0 from Workflow#initialize).
      expect(workflow.instance_variable_get(:@total_tokens)).to eq(0)
      expect(workflow.instance_variable_get(:@total_cost)).to eq(0.0)
    end
  end

  describe "sum invariant (regression guard)" do
    it "keeps total_cost ≈ sum(usage_entries.cost) and total_tokens == sum(input + output) across many calls" do
      [
        [ 100, 50, 0.001 ],
        [ 200, 75, 0.0025 ],
        [ 50, 25, 0.00075 ],
        [ 0, 200, 0.005 ]
      ].each do |input, output, cost|
        workflow.send(:record_usage, agent_class, agent_result(input: input, output: output, cost: cost), :completed_attempt, "model")
      end

      entries = workflow.instance_variable_get(:@usage_entries)
      tokens_total = workflow.instance_variable_get(:@total_tokens)
      cost_total   = workflow.instance_variable_get(:@total_cost)

      expect(tokens_total).to eq(entries.sum { |e| e.input_tokens + e.output_tokens })
      expect(cost_total).to be_within(1e-9).of(entries.map(&:cost).compact.sum)
    end
  end

  describe "parallel-branch attribution (regression guard for the @last_attempt_model fix)" do
    # Before the local-arg fix, the workflow stored `@last_attempt_model`
    # as an ivar that `snapshot_and_finalize` read back. Under parallel
    # fan-out two branches sharing the workflow could race: branch A's
    # success could read branch B's last-set model and attribute the
    # wrong model to branch A's entry. With `model_id` threaded as a
    # local arg, the race is gone — verify by hammering record_usage
    # from many threads with different model ids.
    it "attributes the right model_id to each entry under concurrent recording" do
      threads = 20.times.map do |i|
        Thread.new do
          model = i.even? ? "claude-opus-4-7" : "gemini-2.5-pro"
          workflow.send(
            :record_usage,
            agent_class,
            agent_result(input: 10 + i, output: 5 + i, cost: 0.0001 * i),
            :completed_attempt,
            model
          )
        end
      end
      threads.each(&:join)

      entries = workflow.instance_variable_get(:@usage_entries)
      expect(entries.size).to eq(20)
      models = entries.map(&:model).tally
      expect(models["claude-opus-4-7"]).to eq(10)
      expect(models["gemini-2.5-pro"]).to eq(10)
    end

    it "preserves the rollup invariant under concurrent recording" do
      threads = 20.times.map do |i|
        Thread.new do
          workflow.send(
            :record_usage,
            agent_class,
            agent_result(input: 10, output: 5, cost: 0.0005),
            :completed_attempt,
            "model"
          )
        end
      end
      threads.each(&:join)

      entries = workflow.instance_variable_get(:@usage_entries)
      tokens = workflow.instance_variable_get(:@total_tokens)
      cost   = workflow.instance_variable_get(:@total_cost)

      expect(entries.size).to eq(20)
      expect(tokens).to eq(20 * 15)
      expect(cost).to be_within(1e-9).of(20 * 0.0005)
    end
  end

  describe "nested-workflow rollup" do
    # NestedExecution's `roll_up_child_totals` is invoked from
    # `handle_child_result` BEFORE the failed-step check raises. This
    # ensures a child that did billable agent work and then failed
    # still rolls its entries up to the parent. Drive that helper
    # directly with a synthesized child RunResult.
    let(:parent_workflow) do
      with_stubbed_class("SpecParentRollupWorkflow", workflow_class) do
        initial_state :idle
        state :done
        transition :go, from: :idle, to: :done
      end.new
    end

    def child_entry(usage_id:, model:, attempt_kind: :completed_attempt, input: 100, output: 50, cost: 0.001)
      Smith::Workflow::UsageEntry.new(
        usage_id, :child_agent, model, input, output, cost, attempt_kind, "2026-04-27T12:00:00Z"
      )
    end

    it "rolls up child usage_entries (deep-copied) into the parent" do
      child_entries = [
        child_entry(usage_id: "c-1", model: "claude-opus-4-7"),
        child_entry(usage_id: "c-2", model: "gemini-2.5-flash", attempt_kind: :failed_attempt)
      ]
      child_result = Smith::Workflow::RunResult.new(
        state: :done, output: nil, steps: [], total_cost: 0.001 * 2,
        total_tokens: 150 * 2, context: {}, session_messages: [],
        tool_results: [], outcome: nil, usage_entries: child_entries
      )

      parent_workflow.send(:roll_up_child_totals, child_result)

      parent_entries = parent_workflow.instance_variable_get(:@usage_entries)
      expect(parent_entries.size).to eq(2)
      expect(parent_entries.map(&:usage_id)).to eq(%w[c-1 c-2])
      expect(parent_entries.map(&:attempt_kind)).to eq(%i[completed_attempt failed_attempt])

      # Rollup totals reflect child sums.
      expect(parent_workflow.instance_variable_get(:@total_tokens)).to eq(300)
      expect(parent_workflow.instance_variable_get(:@total_cost)).to be_within(1e-9).of(0.002)
    end

    it "deep-copies child entries (parent and child entries are independent — Struct#dup would be shallow)" do
      original_entry = child_entry(usage_id: "child-original", model: "model-a")
      child_result = Smith::Workflow::RunResult.new(
        state: :done, output: nil, steps: [], total_cost: 0.001,
        total_tokens: 150, context: {}, session_messages: [],
        tool_results: [], outcome: nil, usage_entries: [ original_entry ]
      )

      parent_workflow.send(:roll_up_child_totals, child_result)

      parent_entries = parent_workflow.instance_variable_get(:@usage_entries)
      # Different Struct instance — `Struct#dup` would alias mutable
      # field values, but the rollup uses `from_h(snapshot_value(...))`
      # which produces a fully detached struct.
      expect(parent_entries.first).not_to equal(original_entry)
      # Identity check on the model field too: the rollup's deep-copy
      # via `snapshot_value` recursively duplicates strings, so the
      # parent's `model` is a different String object from the child's.
      expect(parent_entries.first.model).not_to equal(original_entry.model)
      # And the values themselves agree.
      expect(parent_entries.first.model).to eq(original_entry.model)
    end

    it "preserves attempt_kind on rollup (failed-but-billable entries from the child stay :failed_attempt)" do
      child_entries = [
        child_entry(usage_id: "c-fail", model: "fallback-model", attempt_kind: :failed_attempt, input: 50, output: 0, cost: 0.0)
      ]
      child_result = Smith::Workflow::RunResult.new(
        state: :failed, output: nil, steps: [], total_cost: 0.0,
        total_tokens: 50, context: {}, session_messages: [],
        tool_results: [], outcome: nil, usage_entries: child_entries
      )

      parent_workflow.send(:roll_up_child_totals, child_result)

      parent_entries = parent_workflow.instance_variable_get(:@usage_entries)
      expect(parent_entries.first.attempt_kind).to eq(:failed_attempt)
    end
  end
end
