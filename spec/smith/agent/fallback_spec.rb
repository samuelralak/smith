# frozen_string_literal: true

RSpec.describe "Smith::Agent fallback model chains" do
  let(:agent_class) { require_const("Smith::Agent") }
  let(:workflow_class) { require_const("Smith::Workflow") }
  let(:agent_error) { require_const("Smith::AgentError") }
  let(:workflow_error) { require_const("Smith::WorkflowError") }

  it "succeeds on primary model without invoking fallbacks" do
    agent = with_stubbed_class("SpecFallbackPrimaryAgent", agent_class) do
      register_as :spec_fallback_primary
      model "gpt-5-mini"
      fallback_models "gpt-4.1-mini"
    end

    call_count = Concurrent::AtomicFixnum.new(0)
    allow(agent).to receive(:chat) do |**kwargs|
      call_count.increment
      chat = Object.new
      chat.define_singleton_method(:add_message) { |_| nil }
      chat.define_singleton_method(:with_schema) { |_| self }
      chat.define_singleton_method(:complete) { Struct.new(:content, :input_tokens, :output_tokens).new("primary ok", 5, 3) }
      chat
    end

    workflow = with_stubbed_class("SpecFallbackPrimaryWorkflow", workflow_class) do
      initial_state :idle; state :done
      transition :go, from: :idle, to: :done do execute :spec_fallback_primary end
    end.new

    result = workflow.run!

    expect(result.state).to eq(:done)
    expect(result.output).to eq("primary ok")
    expect(call_count.value).to eq(1)
  end

  it "falls through to fallback model on transient upstream failure" do
    agent = with_stubbed_class("SpecFallbackTransientAgent", agent_class) do
      register_as :spec_fallback_transient
      model "gpt-5-mini"
      fallback_models "gpt-4.1-mini"
    end

    models_tried = []
    allow(agent).to receive(:chat) do |**kwargs|
      model = kwargs[:model] || "gpt-5-mini"
      models_tried << model
      chat = Object.new
      chat.define_singleton_method(:add_message) { |_| nil }
      chat.define_singleton_method(:with_schema) { |_| self }
      if model == "gpt-5-mini"
        chat.define_singleton_method(:complete) { raise RubyLLM::ServerError, "500 error" }
      else
        chat.define_singleton_method(:complete) { Struct.new(:content, :input_tokens, :output_tokens).new("fallback ok", 5, 3) }
      end
      chat
    end

    workflow = with_stubbed_class("SpecFallbackTransientWorkflow", workflow_class) do
      initial_state :idle; state :done; state :failed
      transition :go, from: :idle, to: :done do execute :spec_fallback_transient; on_failure :fail end
    end.new

    result = workflow.run!

    expect(result.state).to eq(:done)
    expect(result.output).to eq("fallback ok")
    expect(models_tried).to eq(%w[gpt-5-mini gpt-4.1-mini])
  end

  it "prices a successful fallback attempt against the model that actually succeeded" do
    original_pricing = Smith.config.pricing

    Smith.configure do |config|
      config.pricing = {
        "gpt-5-mini" => {
          input_cost_per_token: 0.10,
          output_cost_per_token: 0.10
        },
        "gpt-4.1-mini" => {
          input_cost_per_token: 0.01,
          output_cost_per_token: 0.02
        }
      }
    end

    agent = with_stubbed_class("SpecFallbackAttemptModelCostAgent", agent_class) do
      register_as :spec_fallback_attempt_model_cost
      model "gpt-5-mini"
      fallback_models "gpt-4.1-mini"
    end

    allow(agent).to receive(:chat) do |**kwargs|
      model = kwargs[:model] || "gpt-5-mini"
      chat = Object.new
      chat.define_singleton_method(:add_message) { |_| nil }
      chat.define_singleton_method(:with_schema) { |_| self }
      if model == "gpt-5-mini"
        chat.define_singleton_method(:complete) { raise RubyLLM::ServerError, "primary down" }
      else
        chat.define_singleton_method(:complete) do
          Struct.new(:content, :input_tokens, :output_tokens).new("fallback ok", 5, 3)
        end
      end
      chat
    end

    workflow = with_stubbed_class("SpecFallbackAttemptModelCostWorkflow", workflow_class) do
      initial_state :idle
      state :done
      state :failed

      transition :go, from: :idle, to: :done do
        execute :spec_fallback_attempt_model_cost
        on_failure :fail
      end
    end.new

    result = workflow.run!

    expect(result.state).to eq(:done)
    expect(result.output).to eq("fallback ok")
    expect(result.total_cost).to eq(0.11)
    expect(result.total_tokens).to eq(8)
  ensure
    Smith.configure { |config| config.pricing = original_pricing }
  end

  it "counts known usage from a failed transient attempt before succeeding on fallback" do
    original_pricing = Smith.config.pricing

    Smith.configure do |config|
      config.pricing = {
        "gpt-5-mini" => {
          input_cost_per_token: 0.01,
          output_cost_per_token: 0.02
        },
        "gpt-4.1-mini" => {
          input_cost_per_token: 0.03,
          output_cost_per_token: 0.04
        }
      }
    end

    agent = with_stubbed_class("SpecFallbackKnownUsageAgent", agent_class) do
      register_as :spec_fallback_known_usage
      model "gpt-5-mini"
      fallback_models "gpt-4.1-mini"
    end

    allow(agent).to receive(:chat) do |**kwargs|
      model = kwargs[:model] || "gpt-5-mini"
      chat = Object.new
      chat.define_singleton_method(:add_message) { |_| nil }
      chat.define_singleton_method(:with_schema) { |_| self }
      if model == "gpt-5-mini"
        chat.define_singleton_method(:complete) do
          error = RubyLLM::ServerError.new("primary transient failure")
          error.define_singleton_method(:input_tokens) { 2 }
          error.define_singleton_method(:output_tokens) { 1 }
          raise error
        end
      else
        chat.define_singleton_method(:complete) do
          Struct.new(:content, :input_tokens, :output_tokens).new("fallback ok", 5, 3)
        end
      end
      chat
    end

    workflow = with_stubbed_class("SpecFallbackKnownUsageWorkflow", workflow_class) do
      initial_state :idle
      state :done
      state :failed

      transition :go, from: :idle, to: :done do
        execute :spec_fallback_known_usage
        on_failure :fail
      end
    end.new

    result = workflow.run!

    expect(result.state).to eq(:done)
    expect(result.total_tokens).to eq(11)
    expect(result.total_cost).to eq(0.31)
  ensure
    Smith.configure { |config| config.pricing = original_pricing }
  end

  it "keeps failed transient attempts optimistic when usage is unknown" do
    original_pricing = Smith.config.pricing

    Smith.configure do |config|
      config.pricing = {
        "gpt-5-mini" => {
          input_cost_per_token: 0.10,
          output_cost_per_token: 0.10
        },
        "gpt-4.1-mini" => {
          input_cost_per_token: 0.01,
          output_cost_per_token: 0.02
        }
      }
    end

    agent = with_stubbed_class("SpecFallbackUnknownUsageAgent", agent_class) do
      register_as :spec_fallback_unknown_usage
      model "gpt-5-mini"
      fallback_models "gpt-4.1-mini"
    end

    allow(agent).to receive(:chat) do |**kwargs|
      model = kwargs[:model] || "gpt-5-mini"
      chat = Object.new
      chat.define_singleton_method(:add_message) { |_| nil }
      chat.define_singleton_method(:with_schema) { |_| self }
      if model == "gpt-5-mini"
        chat.define_singleton_method(:complete) { raise RubyLLM::ServerError, "primary down" }
      else
        chat.define_singleton_method(:complete) do
          Struct.new(:content, :input_tokens, :output_tokens).new("fallback ok", 5, 3)
        end
      end
      chat
    end

    workflow = with_stubbed_class("SpecFallbackUnknownUsageWorkflow", workflow_class) do
      initial_state :idle
      state :done
      state :failed

      transition :go, from: :idle, to: :done do
        execute :spec_fallback_unknown_usage
        on_failure :fail
      end
    end.new

    result = workflow.run!

    expect(result.state).to eq(:done)
    expect(result.total_tokens).to eq(8)
    expect(result.total_cost).to eq(0.11)
  ensure
    Smith.configure { |config| config.pricing = original_pricing }
  end

  it "raises AgentError when the entire fallback chain is exhausted" do
    agent = with_stubbed_class("SpecFallbackExhaustAgent", agent_class) do
      register_as :spec_fallback_exhaust
      model "gpt-5-mini"
      fallback_models "gpt-4.1-mini"
    end

    allow(agent).to receive(:chat) do
      chat = Object.new
      chat.define_singleton_method(:add_message) { |_| nil }
      chat.define_singleton_method(:with_schema) { |_| self }
      chat.define_singleton_method(:complete) { raise RubyLLM::ServerError, "all down" }
      chat
    end

    workflow = with_stubbed_class("SpecFallbackExhaustWorkflow", workflow_class) do
      initial_state :idle; state :done; state :failed
      transition :go, from: :idle, to: :done do execute :spec_fallback_exhaust; on_failure :fail end
    end.new

    result = workflow.run!

    expect(result.state).to eq(:failed)
    expect(result.steps.first[:error]).to be_a(agent_error)
  end

  it "does not fallback on non-transient provider errors" do
    agent = with_stubbed_class("SpecFallbackBadRequestAgent", agent_class) do
      register_as :spec_fallback_bad_request
      model "gpt-5-mini"
      fallback_models "gpt-4.1-mini"
    end

    models_tried = []
    allow(agent).to receive(:chat) do |**kwargs|
      models_tried << (kwargs[:model] || "gpt-5-mini")
      chat = Object.new
      chat.define_singleton_method(:add_message) { |_| nil }
      chat.define_singleton_method(:with_schema) { |_| self }
      chat.define_singleton_method(:complete) { raise RubyLLM::BadRequestError, "invalid" }
      chat
    end

    workflow = with_stubbed_class("SpecFallbackBadRequestWorkflow", workflow_class) do
      initial_state :idle; state :done; state :failed
      transition :go, from: :idle, to: :done do execute :spec_fallback_bad_request; on_failure :fail end
    end.new

    result = workflow.run!

    expect(result.state).to eq(:failed)
    expect(models_tried).to eq(%w[gpt-5-mini])
  end

  it "does not fallback on Smith::Error subclasses" do
    agent = with_stubbed_class("SpecFallbackSmithErrorAgent", agent_class) do
      register_as :spec_fallback_smith_error
      model "gpt-5-mini"
      fallback_models "gpt-4.1-mini"
    end

    workflow = with_stubbed_class("SpecFallbackSmithErrorWorkflow", workflow_class) do
      initial_state :idle; state :done; state :failed
      budget wall_clock: 0
      transition :go, from: :idle, to: :done do execute :spec_fallback_smith_error; on_failure :fail end
    end.new

    sleep 0.01
    result = workflow.run!

    expect(result.state).to eq(:failed)
    expect(result.steps.first[:error]).to be_a(Smith::DeadlineExceeded)
  end

  it "inherits fallback_models in subclasses" do
    parent = with_stubbed_class("SpecFallbackParentAgent", agent_class) do
      model "gpt-5-mini"
      fallback_models "gpt-4.1-mini", "gpt-4.1-nano"
    end

    child = Class.new(parent)

    expect(child.fallback_models).to eq(%w[gpt-4.1-mini gpt-4.1-nano])
  end

  it "works without fallback_models configured (single model behavior)" do
    agent = with_stubbed_class("SpecFallbackNoneAgent", agent_class) do
      register_as :spec_fallback_none
      model "gpt-5-mini"
    end

    allow(agent).to receive(:chat) do
      chat = Object.new
      chat.define_singleton_method(:add_message) { |_| nil }
      chat.define_singleton_method(:with_schema) { |_| self }
      chat.define_singleton_method(:complete) { Struct.new(:content, :input_tokens, :output_tokens).new("ok", 5, 3) }
      chat
    end

    workflow = with_stubbed_class("SpecFallbackNoneWorkflow", workflow_class) do
      initial_state :idle; state :done
      transition :go, from: :idle, to: :done do execute :spec_fallback_none end
    end.new

    result = workflow.run!

    expect(result.state).to eq(:done)
    expect(result.output).to eq("ok")
  end

  it "deduplicates fallback_models while preserving order" do
    agent = with_stubbed_class("SpecFallbackDedupAgent", agent_class) do
      model "gpt-5-mini"
      fallback_models "gpt-4.1-mini", "gpt-4.1-nano", "gpt-4.1-mini"
    end

    expect(agent.fallback_models).to eq(%w[gpt-4.1-mini gpt-4.1-nano])
  end

  it "rejects blank fallback model entries" do
    expect do
      with_stubbed_class("SpecFallbackBlankModelAgent", agent_class) do
        model "gpt-5-mini"
        fallback_models "", "gpt-4.1-mini"
      end
    end.to raise_error(workflow_error, /must not be blank/)
  end
end
