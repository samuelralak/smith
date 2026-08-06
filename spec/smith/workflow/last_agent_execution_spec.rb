# frozen_string_literal: true

require "json"

# The last-serial-agent-execution attribution primitive: a deterministic
# (compute) step can read the model/provider that actually served the most
# recent `execute :agent` step, durable across crash/resume, symmetric with
# `last_output`.
RSpec.describe "Smith::Workflow last agent execution attribution" do
  let(:agent_class) { require_const("Smith::Agent") }
  let(:workflow_class) { require_const("Smith::Workflow") }
  let(:step_class) { require_const("Smith::Workflow::DeterministicStep") }

  let(:adapter) do
    Class.new do
      attr_reader :writes

      def initialize
        @store = {}
        @writes = []
      end

      def store(key, payload)
        @writes << [key, JSON.parse(payload)]
        @store[key] = payload
      end

      def fetch(key) = @store[key]
      def delete(key) = @store.delete(key)
    end.new
  end

  def stub_chat(klass, content:)
    allow(klass).to receive(:chat) do
      chat = Object.new
      chat.define_singleton_method(:add_message) { |_msg| nil }
      chat.define_singleton_method(:with_schema) { |_s| self }
      chat.define_singleton_method(:complete) do
        Struct.new(:content, :input_tokens, :output_tokens).new(content, 5, 3)
      end
      chat
    end
  end

  describe "DeterministicStep readers" do
    it "returns nil when no serial agent step has run" do
      step = step_class.new(
        context: {}, session_messages: [], tool_results: [], state: :idle,
        transition_name: :fold
      )

      expect(step.last_agent_model).to be_nil
      expect(step.last_agent_provider).to be_nil
    end

    it "returns the model/provider of the last agent execution when present" do
      step = step_class.new(
        context: {}, session_messages: [], tool_results: [], state: :idle,
        transition_name: :fold,
        last_agent_execution: { model: "gpt-5-mini", provider: :openai }
      )

      expect(step.last_agent_model).to eq("gpt-5-mini")
      expect(step.last_agent_provider).to eq(:openai)
    end
  end

  describe "execute -> compute integration" do
    it "exposes the served model/provider of the preceding agent step to a compute step" do
      agent = with_stubbed_class("SpecLastAgentAgent", agent_class) do
        register_as :spec_last_agent_agent
        model "gpt-5-mini"
      end
      stub_chat(agent, content: "designed")

      workflow = with_stubbed_class("SpecLastAgentWorkflow", workflow_class) do
        initial_state :idle
        state :drafted
        state :done

        transition :design, from: :idle, to: :drafted do
          execute :spec_last_agent_agent
        end

        transition :fold, from: :drafted, to: :done do
          compute do |step|
            step.write_context(:seen_model, step.last_agent_model)
            step.write_context(:seen_provider, step.last_agent_provider)
            step.write_context(:seen_output, step.last_output)
          end
        end
      end.new

      result = workflow.run!

      entry = result.usage_entries.fetch(0)
      # Self-consistent with Smith's own usage record of the served model/provider,
      # and symmetric with last_output (the same step's content).
      expect(result.context[:seen_model]).to eq(entry.model)
      expect(result.context[:seen_provider]).to eq(entry.provider)
      expect(result.context[:seen_model]).to eq("gpt-5-mini")
      expect(result.context[:seen_output]).to eq("designed")
    end

    it "reports the ACTUAL served fallback model, not the configured primary, after failover" do
      agent = with_stubbed_class("SpecLastAgentFallbackAgent", agent_class) do
        register_as :spec_last_agent_fallback_agent
        model "gpt-5-mini"
        fallback_models ["anthropic/claude-sonnet-4-6"]
      end
      calls = Concurrent::AtomicFixnum.new(0)
      allow(agent).to receive(:chat) do
        chat = Object.new
        chat.define_singleton_method(:add_message) { |_msg| nil }
        chat.define_singleton_method(:with_schema) { |_s| self }
        if calls.increment == 1
          chat.define_singleton_method(:complete) { raise RubyLLM::ServerError, "primary transient failure" }
        else
          chat.define_singleton_method(:complete) do
            Struct.new(:content, :input_tokens, :output_tokens).new("repaired", 5, 3)
          end
        end
        chat
      end

      workflow = with_stubbed_class("SpecLastAgentFallbackWorkflow", workflow_class) do
        initial_state :idle
        state :drafted
        state :done

        transition :design, from: :idle, to: :drafted do
          execute :spec_last_agent_fallback_agent
        end

        transition :fold, from: :drafted, to: :done do
          compute { |step| step.write_context(:seen_model, step.last_agent_model) }
        end
      end.new

      result = workflow.run!

      completed = result.usage_entries.find { |entry| entry.attempt_kind == :completed_attempt }
      # The served model is the fallback that actually completed, never the
      # configured primary that failed - the truthfulness guarantee.
      expect(result.context[:seen_model]).to eq(completed.model)
      expect(result.context[:seen_model]).not_to eq("gpt-5-mini")
    end
  end

  describe "durability across crash/resume" do
    it "restores the attribution so a compute step resuming after the agent step still reads it" do
      agent = with_stubbed_class("SpecLastAgentResumeAgent", agent_class) do
        register_as :spec_last_agent_resume_agent
        model "gpt-5-mini"
      end
      stub_chat(agent, content: "designed")

      klass = with_stubbed_class("SpecLastAgentResumeWorkflow", workflow_class) do
        initial_state :idle
        state :drafted
        state :done

        transition :design, from: :idle, to: :drafted do
          execute :spec_last_agent_resume_agent
        end

        transition :fold, from: :drafted, to: :done do
          compute { |step| step.write_context(:seen_model, step.last_agent_model) }
        end
      end

      klass.new.run_persisted!("wf:resume", adapter:)

      # Take the checkpoint persisted AFTER the agent step (state drafted) and
      # resume a fresh workflow from it into a new adapter - a crash between the
      # agent step and the compute step.
      drafted = adapter.writes.reverse.find { |(_, state)| (state["state"] || state[:state]) == "drafted" }
      expect(drafted).not_to be_nil

      resume_adapter = adapter.class.new
      resume_adapter.store("wf:resume", JSON.generate(drafted.last))
      resumed = klass.restore("wf:resume", adapter: resume_adapter)

      result = resumed.run!

      expect(result.state).to eq(:done)
      expect(result.context[:seen_model]).to eq("gpt-5-mini")
    end
  end
end
