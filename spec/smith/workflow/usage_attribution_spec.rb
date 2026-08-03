# frozen_string_literal: true

require "json"

RSpec.describe "Smith usage attribution and provider-call timing" do
  let(:agent_class) { require_const("Smith::Agent") }
  let(:workflow_class) { require_const("Smith::Workflow") }
  let(:tool_class) { require_const("Smith::Tool") }
  let(:memory_trace_class) { require_const("Smith::Trace::Memory") }
  let(:usage_entry_class) { require_const("Smith::Workflow::UsageEntry") }

  let(:adapter) do
    Class.new do
      def initialize = @store = {}
      def store(key, payload) = @store[key] = payload
      def fetch(key) = @store[key]
      def delete(key) = @store.delete(key)
    end.new
  end

  def with_trace_adapter(trace_adapter)
    original_adapter = Smith.config.trace_adapter

    Smith.configure { |config| config.trace_adapter = trace_adapter }
    Smith::Trace.reset!
    yield
  ensure
    Smith.configure { |config| config.trace_adapter = original_adapter }
    Smith::Trace.reset!
  end

  def stub_chat_agent(klass, content: "ok", input_tokens: 5, output_tokens: 3)
    allow(klass).to receive(:chat) do
      chat = Object.new
      chat.define_singleton_method(:add_message) { |_msg| nil }
      chat.define_singleton_method(:with_schema) { |_s| self }
      chat.define_singleton_method(:complete) do
        Struct.new(:content, :input_tokens, :output_tokens).new(content, input_tokens, output_tokens)
      end
      chat
    end
  end

  describe "UsageEntry attribution members" do
    it "round-trips the attribution members through JSON with symbol restoration" do
      entry = usage_entry_class.new(
        usage_id: "u-1", agent_name: :writer, model: "gpt-5-mini", provider: :openai,
        input_tokens: 10, output_tokens: 4, cost: 0.01, attempt_kind: :completed_attempt,
        recorded_at: "2026-08-02T00:00:00.000001Z",
        transition: :draft, branch_key: :left, round: 2, attempt_id: "a-1"
      )

      restored = usage_entry_class.from_h(JSON.parse(JSON.generate(entry.to_h)))

      expect(restored.transition).to eq(:draft)
      expect(restored.branch_key).to eq(:left)
      expect(restored.round).to eq(2)
      expect(restored.attempt_id).to eq("a-1")
      expect(restored).to eq(entry)
    end

    # from_h symbolizes transition/branch_key on restore, so recording must
    # symbolize the same way: a host seeding Strings through
    # Smith::Attribution.with must not produce an entry that differs from
    # its own restored form.
    it "records host-seeded String attribution as Symbols so restore equals recording" do
      workflow = with_stubbed_class("SpecCoercionWorkflow", workflow_class) do
        initial_state :idle
        state :done

        transition :finish, from: :idle, to: :done
      end.new
      agent = with_stubbed_class("SpecCoercionAgent", agent_class) { register_as :spec_coercion_agent }
      agent_result = Smith::Workflow::AgentResult.new(
        content: "ok", input_tokens: 5, output_tokens: 3, cost: nil,
        model_used: "gpt-5-mini", provider_used: nil
      )

      reference = Smith::Agent::ModelReference.new(model_id: "gpt-5-mini", provider: nil)
      entry = Smith::Attribution.with(transition: "string_step", branch_key: "string_branch") do
        workflow.send(:build_usage_entry, agent, agent_result, :completed_attempt, reference)
      end

      expect(entry.transition).to eq(:string_step)
      expect(entry.branch_key).to eq(:string_branch)
      restored = usage_entry_class.from_h(JSON.parse(JSON.generate(entry.to_h)))
      expect(restored).to eq(entry)
    end

    it "re-serializes entries restored from earlier Smith versions byte-identically" do
      legacy = {
        "usage_id" => SecureRandom.uuid, "agent_name" => "writer", "model" => "m", "provider" => "openai",
        "input_tokens" => 1, "output_tokens" => 1, "cost" => nil,
        "attempt_kind" => "completed_attempt", "recorded_at" => "2026-01-01T00:00:00Z"
      }

      restored = usage_entry_class.from_h(legacy)

      # Hosts digest whole persisted documents in exact-mutation proofs: a
      # restored pre-attribution entry must not grow nil attribution keys.
      expect(restored.to_h.keys.map(&:to_s).sort).to eq(legacy.keys.sort)
    end

    it "restores entries persisted by earlier Smith versions with nil attribution" do
      legacy = {
        "usage_id" => "u-2", "agent_name" => "writer", "model" => "m", "provider" => "openai",
        "input_tokens" => 1, "output_tokens" => 1, "cost" => nil,
        "attempt_kind" => "completed_attempt", "recorded_at" => "2026-01-01T00:00:00Z"
      }

      restored = usage_entry_class.from_h(legacy)

      expect(restored.transition).to be_nil
      expect(restored.branch_key).to be_nil
      expect(restored.round).to be_nil
      expect(restored.attempt_id).to be_nil
    end
  end

  describe "workflow recording" do
    it "tags entries with the step transition and joins the provider_call trace by attempt id" do
      stubbed = with_stubbed_class("SpecUsageAttributionAgent", agent_class) do
        register_as :spec_usage_attribution_agent
        model "gpt-5-mini"
      end
      stub_chat_agent(stubbed)
      trace_adapter = memory_trace_class.new

      workflow = with_stubbed_class("SpecUsageAttributionWorkflow", workflow_class) do
        initial_state :idle
        state :done

        transition :finish, from: :idle, to: :done do
          execute :spec_usage_attribution_agent
        end
      end.new

      result = nil
      with_trace_adapter(trace_adapter) { result = workflow.run! }

      entry = result.usage_entries.fetch(0)
      expect(entry.transition).to eq(:finish)
      expect(entry.workflow).to eq("SpecUsageAttributionWorkflow")
      expect(entry.branch_key).to be_nil
      expect(entry.round).to be_nil
      expect(entry.attempt_id).to match(/\A[0-9a-f-]{36}\z/)
      expect(entry.recorded_at).to match(/\.\d{6}Z?\z/)

      provider_calls = trace_adapter.traces.select { |t| t[:type] == :provider_call }
      expect(provider_calls.length).to eq(1)
      data = provider_calls.first[:data]
      expect(data[:attempt_id]).to eq(entry.attempt_id)
      expect(data[:duration_ms]).to be_a(Integer)
      expect(data[:duration_ms]).to be >= 0
      expect(data[:outcome]).to eq(:success)
      expect(data[:attempt_index]).to eq(0)
      expect(data[:transition]).to eq(:finish)
    end

    it "emits one provider_call per attempt across a fallback chain" do
      stubbed = with_stubbed_class("SpecUsageFallbackAgent", agent_class) do
        register_as :spec_usage_fallback_agent
        model "gpt-5-mini"
        fallback_models ["anthropic/claude-sonnet-4-6"]
      end
      calls = Concurrent::AtomicFixnum.new(0)
      allow(stubbed).to receive(:chat) do
        chat = Object.new
        chat.define_singleton_method(:add_message) { |_msg| nil }
        chat.define_singleton_method(:with_schema) { |_s| self }
        if calls.increment == 1
          chat.define_singleton_method(:complete) { raise RubyLLM::ServerError, "primary transient failure" }
        else
          chat.define_singleton_method(:complete) do
            Struct.new(:content, :input_tokens, :output_tokens).new("recovered", 7, 2)
          end
        end
        chat
      end
      trace_adapter = memory_trace_class.new

      workflow = with_stubbed_class("SpecUsageFallbackWorkflow", workflow_class) do
        initial_state :idle
        state :done

        transition :finish, from: :idle, to: :done do
          execute :spec_usage_fallback_agent
        end
      end.new

      result = nil
      with_trace_adapter(trace_adapter) { result = workflow.run! }

      expect(result.state).to eq(:done)
      provider_calls = trace_adapter.traces.select { |t| t[:type] == :provider_call }
      expect(provider_calls.map { |t| t[:data][:outcome] }).to eq(%i[failure success])
      expect(provider_calls.map { |t| t[:data][:attempt_index] }).to eq([0, 1])
      expect(provider_calls.map { |t| t[:data][:attempt_id] }.uniq.length).to eq(2)
    end

    it "emits an aborted provider_call when a non-provider error re-raises" do
      stubbed = with_stubbed_class("SpecUsageAbortedAgent", agent_class) do
        register_as :spec_usage_aborted_agent
        model "gpt-5-mini"
      end
      allow(stubbed).to receive(:chat) do
        chat = Object.new
        chat.define_singleton_method(:add_message) { |_msg| nil }
        chat.define_singleton_method(:with_schema) { |_s| self }
        chat.define_singleton_method(:complete) { raise ArgumentError, "tool programming error" }
        chat
      end
      trace_adapter = memory_trace_class.new

      workflow = with_stubbed_class("SpecUsageAbortedWorkflow", workflow_class) do
        initial_state :idle
        state :running
        state :failed

        transition :start, from: :idle, to: :running do
          execute :spec_usage_aborted_agent
          on_failure :fail
        end
      end.new

      result = nil
      with_trace_adapter(trace_adapter) { result = workflow.run! }

      # The non-provider error still fails the step, and the attempt that
      # died is visible: prefix-accounted entries always have a join target.
      expect(result.state).to eq(:failed)
      provider_calls = trace_adapter.traces.select { |t| t[:type] == :provider_call }
      expect(provider_calls.length).to eq(1)
      expect(provider_calls.first[:data][:outcome]).to eq(:aborted)
      expect(provider_calls.first[:data][:attempt_id]).to match(/\A[0-9a-f-]{36}\z/)
    end

    it "suppresses provider_call traces when trace_provider_calls is false" do
      stubbed = with_stubbed_class("SpecUsageQuietAgent", agent_class) do
        register_as :spec_usage_quiet_agent
        model "gpt-5-mini"
      end
      stub_chat_agent(stubbed)
      trace_adapter = memory_trace_class.new
      original = Smith.config.trace_provider_calls

      workflow = with_stubbed_class("SpecUsageQuietWorkflow", workflow_class) do
        initial_state :idle
        state :done

        transition :finish, from: :idle, to: :done do
          execute :spec_usage_quiet_agent
        end
      end.new

      begin
        Smith.configure { |config| config.trace_provider_calls = false }
        with_trace_adapter(trace_adapter) { workflow.run! }
      ensure
        Smith.configure { |config| config.trace_provider_calls = original }
      end

      expect(trace_adapter.traces.select { |t| t[:type] == :provider_call }).to be_empty
    end
  end

  describe "public usage_entries reader" do
    it "returns a frozen copy without serializing the whole state" do
      workflow = with_stubbed_class("SpecUsageReaderWorkflow", workflow_class) do
        initial_state :idle
        state :done

        transition :finish, from: :idle, to: :done
      end.new

      entries = workflow.usage_entries

      expect(entries).to eq([])
      expect(entries).to be_frozen
    end
  end

  describe "event correlation identity" do
    it "stamps StepCompleted with the persistence key during a persisted run" do
      klass = with_stubbed_class("SpecEventIdentityWorkflow", workflow_class) do
        initial_state :idle
        state :done

        transition :finish, from: :idle, to: :done
      end
      observed = []
      Smith::Events.on(Smith::Events::StepCompleted) { |event| observed << event }

      klass.new.run_persisted!("wf:event-identity", adapter:)

      expect(observed.length).to eq(1)
      expect(observed.first.execution_id).to eq("wf:event-identity")
      expect(observed.first.trace_id).to eq("wf:event-identity")
    end

    it "falls back to random ids outside any execution scope" do
      first = Smith::Events::StepCompleted.new(transition: :a, from: nil, to: :b)
      second = Smith::Events::StepCompleted.new(transition: :a, from: nil, to: :b)

      expect(first.execution_id).not_to eq(second.execution_id)
    end
  end

  describe "tool trace correlation" do
    it "includes tool_call_id when an invocation identity is ambient" do
      traced_tool = with_stubbed_class("SpecUsageTracedTool", tool_class) do
        def perform(**kwargs)
          kwargs
        end
      end
      invocation = tool_class::Invocation.new(
        tool_call_id: "call-123", tool_name: "spec_usage_traced_tool",
        ordinal: 1, batch_ordinal: 1, batch_size: 1
      )
      trace_adapter = memory_trace_class.new

      with_trace_adapter(trace_adapter) do
        values = tool_class::ScopedContext.capture.merge(current_invocation: invocation)
        tool_class::ScopedContext.around(values) do
          traced_tool.new.execute(query: "status")
        end
      end

      tool_trace = trace_adapter.traces.find { |t| t[:type] == :tool_call }
      expect(tool_trace[:data][:tool_call_id]).to eq("call-123")
    end

    it "stamps tool_call_id on the capture entry for batch-originated invocations" do
      captured_entries = []
      capturing_tool = with_stubbed_class("SpecUsageCaptureTool", tool_class) do
        capture_result { |_kwargs, result| result }

        def perform(**kwargs)
          kwargs
        end
      end
      invocation = tool_class::Invocation.new(
        tool_call_id: "call-777", tool_name: "spec_usage_capture_tool",
        ordinal: 1, batch_ordinal: 1, batch_size: 1
      )

      values = tool_class::ScopedContext.capture.merge(
        current_invocation: invocation,
        current_tool_result_collector: ->(entry) { captured_entries << entry }
      )
      tool_class::ScopedContext.around(values) do
        capturing_tool.new.execute(query: "status")
      end

      expect(captured_entries.length).to eq(1)
      expect(captured_entries.first[:tool_call_id]).to eq("call-777")
      expect(captured_entries.first.keys).to contain_exactly(:tool, :captured, :tool_call_id)
    end

    it "keeps the exact two-key capture shape for direct invocations" do
      captured_entries = []
      capturing_tool = with_stubbed_class("SpecUsageDirectCaptureTool", tool_class) do
        capture_result { |_kwargs, result| result }

        def perform(**kwargs)
          kwargs
        end
      end

      values = tool_class::ScopedContext.capture.merge(
        current_tool_result_collector: ->(entry) { captured_entries << entry }
      )
      tool_class::ScopedContext.around(values) do
        capturing_tool.new.execute(query: "status")
      end

      expect(captured_entries.length).to eq(1)
      expect(captured_entries.first.keys).to contain_exactly(:tool, :captured)
    end

    it "omits tool_call_id for direct invocations" do
      traced_tool = with_stubbed_class("SpecUsageDirectTool", tool_class) do
        def perform(**kwargs)
          kwargs
        end
      end
      trace_adapter = memory_trace_class.new

      with_trace_adapter(trace_adapter) do
        traced_tool.new.execute(query: "status")
      end

      tool_trace = trace_adapter.traces.find { |t| t[:type] == :tool_call }
      expect(tool_trace[:data]).not_to have_key(:tool_call_id)
    end
  end

  describe "composite effects key contract" do
    let(:effects_class) { require_const("Smith::Workflow::Composite::Effects") }

    def effects_for(entry_hash)
      effects_class.new(
        usage_entries: [entry_hash],
        tool_results: [],
        budget_consumed: {}
      )
    end

    let(:legacy_entry) do
      {
        "usage_id" => SecureRandom.uuid, "agent_name" => "writer", "model" => "m", "provider" => "openai",
        "input_tokens" => 1, "output_tokens" => 1, "cost" => nil,
        "attempt_kind" => "completed_attempt", "recorded_at" => "2026-01-01T00:00:00Z"
      }
    end

    it "accepts entries from earlier Smith versions without attribution keys" do
      expect { effects_for(legacy_entry) }.not_to raise_error
    end

    it "accepts current entries carrying attribution keys" do
      current = legacy_entry.merge(
        "transition" => "draft", "branch_key" => "left", "round" => 1,
        "attempt_id" => SecureRandom.uuid, "workflow" => "SpecEffectsWorkflow"
      )

      expect { effects_for(current) }.not_to raise_error
    end

    it "rejects unknown keys" do
      expect { effects_for(legacy_entry.merge("smuggled" => true)) }
        .to raise_error(ArgumentError, /composite usage entry attributes are invalid/)
    end

    it "rejects entries missing required keys" do
      expect { effects_for(legacy_entry.except("usage_id")) }
        .to raise_error(ArgumentError, /composite usage entry attributes are invalid/)
    end

    # The optional keys are bounded values, not just bounded keys: a present
    # key with a wrong-typed, empty, oversized, or non-UUID value rejects,
    # so a corrupted or adversarial persisted effects payload cannot smuggle
    # unbounded data through the attribution keys.
    it "accepts nil agent_name and provider but rejects false" do
      expect { effects_for(legacy_entry.merge("agent_name" => nil, "provider" => nil)) }.not_to raise_error
      expect { effects_for(legacy_entry.merge("agent_name" => false)) }
        .to raise_error(ArgumentError, /agent_name must be a non-empty String/)
    end

    it "rejects a non-String workflow value" do
      expect { effects_for(legacy_entry.merge("workflow" => 123)) }
        .to raise_error(ArgumentError, /workflow must be a bounded non-empty String/)
    end

    it "rejects an oversized transition value" do
      expect { effects_for(legacy_entry.merge("transition" => "x" * 257)) }
        .to raise_error(ArgumentError, /transition must be a bounded non-empty String/)
    end

    it "rejects a non-UUID attempt_id" do
      expect { effects_for(legacy_entry.merge("attempt_id" => "z" * 500)) }
        .to raise_error(ArgumentError, /attempt_id must be a UUID/)
    end

    it "rejects a non-Integer round" do
      expect { effects_for(legacy_entry.merge("round" => "1")) }
        .to raise_error(ArgumentError, /round must be a non-negative Integer/)
    end

    describe "tool results" do
      def effects_for_tool(tool_entry)
        effects_class.new(usage_entries: [], tool_results: [tool_entry], budget_consumed: {})
      end

      it "accepts a capture entry carrying a bounded tool_call_id" do
        entry = { "tool" => "web_search", "captured" => { "status" => "ok" }, "tool_call_id" => "call_abc123" }

        expect { effects_for_tool(entry) }.not_to raise_error
      end

      it "accepts the pre-existing two-key capture shape" do
        expect { effects_for_tool({ "tool" => "web_search", "captured" => { "status" => "ok" } }) }
          .not_to raise_error
      end

      it "rejects a nil tool_call_id (the producer never writes one)" do
        entry = { "tool" => "web_search", "captured" => {}, "tool_call_id" => nil }

        expect { effects_for_tool(entry) }
          .to raise_error(ArgumentError, /tool_call_id must be a bounded non-empty String/)
      end

      it "rejects an oversized tool_call_id" do
        entry = { "tool" => "web_search", "captured" => {}, "tool_call_id" => "c" * 1025 }

        expect { effects_for_tool(entry) }
          .to raise_error(ArgumentError, /tool_call_id must be a bounded non-empty String/)
      end
    end
  end
end
