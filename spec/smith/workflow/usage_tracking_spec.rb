# frozen_string_literal: true

require "json"

RSpec.describe "Smith::Workflow usage tracking" do
  let(:workflow_class) { require_const("Smith::Workflow") }

  describe "Workflow::UsageEntry struct" do
    it "round-trips through to_h / from_h preserving all fields" do
      original = Smith::Workflow::UsageEntry.new(
        "abc-123",
        :writer_agent,
        "claude-opus-4-7",
        100,
        50,
        0.00375,
        :completed_attempt,
        "2026-04-27T12:34:56Z"
      )

      restored = Smith::Workflow::UsageEntry.from_h(original.to_h)

      expect(restored.usage_id).to eq("abc-123")
      expect(restored.agent_name).to eq(:writer_agent)
      expect(restored.model).to eq("claude-opus-4-7")
      expect(restored.input_tokens).to eq(100)
      expect(restored.output_tokens).to eq(50)
      expect(restored.cost).to eq(0.00375)
      expect(restored.attempt_kind).to eq(:completed_attempt)
      expect(restored.recorded_at).to eq("2026-04-27T12:34:56Z")
    end

    it "coerces stringified symbols on from_h (JSON round-trip)" do
      stringified_hash = {
        "usage_id" => "id-1",
        "agent_name" => "writer_agent",
        "model" => "gemini-2.5-flash",
        "input_tokens" => 5,
        "output_tokens" => 3,
        "cost" => 0.0,
        "attempt_kind" => "failed_attempt",
        "recorded_at" => "2026-04-27T00:00:00Z"
      }

      restored = Smith::Workflow::UsageEntry.from_h(stringified_hash)
      expect(restored.agent_name).to eq(:writer_agent)
      expect(restored.attempt_kind).to eq(:failed_attempt)
    end
  end

  describe "RunResult keyword construction" do
    it "routes kwargs to the correct fields (regression: plain Struct would put kwargs in :state)" do
      result = Smith::Workflow::RunResult.new(
        state: :done,
        output: "hello",
        steps: [],
        total_cost: 0.5,
        total_tokens: 10,
        context: { topic: "x" },
        session_messages: [],
        tool_results: [],
        outcome: nil,
        usage_entries: []
      )

      expect(result.state).to eq(:done)
      expect(result.output).to eq("hello")
      expect(result.total_cost).to eq(0.5)
      expect(result.total_tokens).to eq(10)
      expect(result.context).to eq(topic: "x")
      expect(result.usage_entries).to eq([])
    end
  end

  describe "fresh-run RunResult" do
    it "exposes usage_entries as part of the documented surface" do
      workflow = with_stubbed_class("SpecUsageEntriesShape", workflow_class) do
        initial_state :idle
        state :done
        transition :go, from: :idle, to: :done
      end.new

      result = workflow.run!
      expect(result).to respond_to(:usage_entries)
      expect(result.usage_entries).to eq([])
    end
  end

  describe "persistence backward compatibility" do
    it "restores @usage_entries to [] when the persisted state predates this slice" do
      workflow_klass = with_stubbed_class("SpecBackwardCompatWorkflow", workflow_class) do
        persistence_key { |_ctx| "workflow:bc" }
        initial_state :idle
        state :done
        transition :go, from: :idle, to: :done
      end

      # State hash from a hypothetical pre-patch Smith — no usage_entries,
      # last_output, last_failed_step keys.
      pre_patch_state = {
        class: "SpecBackwardCompatWorkflow",
        state: "idle",
        persistence_key: "workflow:bc",
        context: {},
        budget_consumed: {},
        step_count: 0,
        execution_namespace: nil,
        created_at: Time.now.utc.iso8601,
        updated_at: Time.now.utc.iso8601,
        next_transition_name: nil,
        session_messages: [],
        total_cost: 0.0,
        total_tokens: 0,
        tool_results: [],
        outcome: nil
      }

      restored = workflow_klass.from_state(pre_patch_state)
      expect(restored.instance_variable_get(:@usage_entries)).to eq([])
      expect(restored.instance_variable_get(:@last_output)).to be_nil
      expect(restored.instance_variable_get(:@last_failed_step)).to be_nil
    end
  end

  describe "restored workflow has @usage_mutex available" do
    it "doesn't NoMethodError on nil when from_state is followed by usage recording" do
      workflow_klass = with_stubbed_class("SpecRestoredMutexWorkflow", workflow_class) do
        persistence_key { |_ctx| "workflow:rm" }
        initial_state :idle
        state :done
        transition :go, from: :idle, to: :done
      end

      original = workflow_klass.new(context: {})
      state = original.to_state
      restored = workflow_klass.from_state(state)

      # Smoke: the restored mutex must be a real Mutex, not nil
      mutex = restored.instance_variable_get(:@usage_mutex)
      expect(mutex).to be_a(Mutex)

      # And the synchronize block actually works
      expect { mutex.synchronize { :ok } }.not_to raise_error
    end
  end

  describe "last_output preservation across persist/restore" do
    it "survives a true value through to_state / from_state" do
      workflow_klass = with_stubbed_class("SpecOutputTrueWorkflow", workflow_class) do
        persistence_key { |_ctx| "workflow:out:true" }
        initial_state :idle
      end

      original = workflow_klass.new
      original.instance_variable_set(:@last_output, "hello world")

      state = JSON.parse(JSON.generate(original.to_state))
      restored = workflow_klass.from_state(state)

      expect(restored.instance_variable_get(:@last_output)).to eq("hello world")
    end

    it "preserves a `false` value (regression: `||` restore would drop it)" do
      workflow_klass = with_stubbed_class("SpecOutputFalseWorkflow", workflow_class) do
        persistence_key { |_ctx| "workflow:out:false" }
        initial_state :idle
      end

      original = workflow_klass.new
      original.instance_variable_set(:@last_output, false)

      state = JSON.parse(JSON.generate(original.to_state))
      restored = workflow_klass.from_state(state)

      expect(restored.instance_variable_get(:@last_output)).to eq(false)
    end
  end

  describe "last_failed_step persistence + reconstruction" do
    let(:workflow_klass) do
      with_stubbed_class("SpecFailedStepWorkflow", workflow_class) do
        persistence_key { |_ctx| "workflow:fs" }
        initial_state :failed
      end
    end

    it "synthesizes last_error from @last_failed_step on terminal-failed restore (DSF preserves retryable)" do
      original = workflow_klass.new
      original.instance_variable_set(:@last_failed_step, {
        transition: :run,
        from: :idle,
        to: :failed,
        error_class: "Smith::DeterministicStepFailure",
        error_family: "deterministic_step_failure",
        error_message: "tool outage",
        error_retryable: true,
        error_kind: :tool_outage,
        error_details: { source: :web }
      })

      state = JSON.parse(JSON.generate(original.to_state))
      restored = workflow_klass.from_state(state)

      result = restored.send(:build_run_result, [])
      expect(result.last_error).to be_a(Smith::DeterministicStepFailure)
      expect(result.last_error.message).to eq("tool outage")
      expect(result.last_error.retryable).to eq(true)
      expect(result.last_error.kind).to eq(:tool_outage)
      # error_details is JSON-normalized: symbol values become strings
      expect(result.last_error.details).to eq("source" => "web")
      expect(result.failure_detail[:transition]).to eq(:run)
    end

    it "uses the family fallback when const_get succeeds but kwargs would be lost (custom DSF subclass)" do
      stub_const("CustomCustomDsf", Class.new(Smith::DeterministicStepFailure) do
        def initialize(msg)
          super(msg)
        end
      end)
      workflow_klass = with_stubbed_class("SpecFamilyFallbackWorkflow", workflow_class) do
        persistence_key { |_ctx| "workflow:ff" }
        initial_state :failed
      end

      original = workflow_klass.new
      original.instance_variable_set(:@last_failed_step, {
        transition: :run,
        from: :idle,
        to: :failed,
        error_class: "CustomCustomDsf",
        error_family: "deterministic_step_failure",
        error_message: "boom",
        error_retryable: true,
        error_kind: :weird,
        error_details: nil
      })

      state = JSON.parse(JSON.generate(original.to_state))
      restored = workflow_klass.from_state(state)

      result = restored.send(:build_run_result, [])
      # Family fallback rebuilds as the parent DSF (preserves retryable)
      expect(result.last_error).to be_a(Smith::DeterministicStepFailure)
      expect(result.last_error.retryable).to eq(true)
      expect(result.last_error.kind).to eq(:weird)
    end

    it "falls back via family when error_class can't be resolved (NameError)" do
      workflow_klass = with_stubbed_class("SpecVanishedClassWorkflow", workflow_class) do
        persistence_key { |_ctx| "workflow:vc" }
        initial_state :failed
      end

      original = workflow_klass.new
      original.instance_variable_set(:@last_failed_step, {
        transition: :run,
        from: :idle,
        to: :failed,
        error_class: "VanishedClass",
        error_family: "agent_error",
        error_message: "old class is gone",
        error_retryable: nil,
        error_kind: nil,
        error_details: nil
      })

      result = original.send(:build_run_result, [])
      expect(result.last_error).to be_a(Smith::AgentError)
      expect(result.last_error.message).to eq("old class is gone")
    end

    it "doesn't synthesize an error when the workflow reached :done (cleared snapshot)" do
      done_workflow_klass = with_stubbed_class("SpecDoneNoSynthWorkflow", workflow_class) do
        persistence_key { |_ctx| "workflow:dns" }
        initial_state :done
      end

      done = done_workflow_klass.new
      done.instance_variable_set(:@last_failed_step, {
        transition: :recover,
        from: :failed,
        to: :done,
        error_class: "Smith::AgentError",
        error_family: "agent_error",
        error_message: "should not be synthesized",
        error_retryable: nil,
        error_kind: nil,
        error_details: nil
      })

      # build_run_result with empty steps + state == :done → no synthesis
      result = done.send(:build_run_result, [])
      expect(result.last_error).to be_nil
      expect(result.failure_detail).to be_nil
    end
  end

  describe ".persisted_state_exists?" do
    let(:adapter) do
      Class.new do
        def initialize
          @store = {}
        end

        def store(key, payload)
          @store[key] = payload
        end

        def fetch(key)
          @store[key]
        end

        def delete(key)
          @store.delete(key)
        end
      end.new
    end

    it "returns false when no state has been persisted" do
      workflow_klass = with_stubbed_class("SpecPeekFalseWorkflow", workflow_class) do
        persistence_key { |_ctx| "workflow:peek-false" }
        initial_state :idle
      end

      expect(workflow_klass.persisted_state_exists?(context: {}, adapter: adapter)).to eq(false)
    end

    it "returns true after persist!, then false again after clear_persisted!" do
      workflow_klass = with_stubbed_class("SpecPeekRoundTripWorkflow", workflow_class) do
        persistence_key { |_ctx| "workflow:peek-rt" }
        initial_state :idle
      end

      original = workflow_klass.new
      original.persist!("workflow:peek-rt", adapter: adapter)

      expect(workflow_klass.persisted_state_exists?(context: {}, adapter: adapter)).to eq(true)

      original.clear_persisted!("workflow:peek-rt", adapter: adapter)
      expect(workflow_klass.persisted_state_exists?(context: {}, adapter: adapter)).to eq(false)
    end
  end

  describe ".restorable_billing_state?" do
    let(:adapter) do
      Class.new do
        def initialize
          @store = {}
        end

        def store(key, payload)
          @store[key] = payload
        end

        def fetch(key)
          @store[key]
        end

        def delete(key)
          @store.delete(key)
        end
      end.new
    end

    it "returns false when no state has been persisted" do
      workflow_klass = with_stubbed_class("SpecBillingPeekNoneWorkflow", workflow_class) do
        persistence_key { |_ctx| "workflow:billing-none" }
        initial_state :idle
      end

      expect(workflow_klass.restorable_billing_state?(context: {}, adapter: adapter)).to eq(false)
    end

    it "returns false for bare initial-state persistence (no usage_entries yet)" do
      # This is the load-bearing case: Smith's `run_persisted!` writes
      # initial state at the top, BEFORE the first `advance!`. A worker
      # crash in that window leaves persisted state with zero billable
      # work. The credits-guard bypass must NOT skip on that state.
      workflow_klass = with_stubbed_class("SpecBillingPeekInitOnlyWorkflow", workflow_class) do
        persistence_key { |_ctx| "workflow:billing-init" }
        initial_state :idle
      end

      original = workflow_klass.new
      original.persist!("workflow:billing-init", adapter: adapter)

      expect(workflow_klass.persisted_state_exists?(context: {}, adapter: adapter)).to eq(true)
      expect(workflow_klass.restorable_billing_state?(context: {}, adapter: adapter)).to eq(false)
    end

    it "returns true once usage_entries have been recorded (preserved billable work)" do
      workflow_klass = with_stubbed_class("SpecBillingPeekWithEntriesWorkflow", workflow_class) do
        persistence_key { |_ctx| "workflow:billing-entries" }
        initial_state :idle
      end

      original = workflow_klass.new
      entry = Smith::Workflow::UsageEntry.new(
        "abc-123", :writer_agent, "claude-opus-4-7",
        100, 50, 0.00175, :completed_attempt,
        "2026-04-27T12:00:00Z"
      )
      original.instance_variable_get(:@usage_entries) << entry
      original.persist!("workflow:billing-entries", adapter: adapter)

      expect(workflow_klass.restorable_billing_state?(context: {}, adapter: adapter)).to eq(true)
    end

    it "returns false again after clear_persisted!" do
      workflow_klass = with_stubbed_class("SpecBillingPeekClearedWorkflow", workflow_class) do
        persistence_key { |_ctx| "workflow:billing-cleared" }
        initial_state :idle
      end

      original = workflow_klass.new
      original.instance_variable_get(:@usage_entries) << Smith::Workflow::UsageEntry.new(
        "abc-123", :writer_agent, "model", 100, 50, 0.001,
        :completed_attempt, "2026-04-27T12:00:00Z"
      )
      original.persist!("workflow:billing-cleared", adapter: adapter)
      expect(workflow_klass.restorable_billing_state?(context: {}, adapter: adapter)).to eq(true)

      original.clear_persisted!("workflow:billing-cleared", adapter: adapter)
      expect(workflow_klass.restorable_billing_state?(context: {}, adapter: adapter)).to eq(false)
    end
  end
end
