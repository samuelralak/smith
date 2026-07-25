# frozen_string_literal: true

RSpec.describe "Smith::Agent fallback model chains" do
  let(:agent_class) { require_const("Smith::Agent") }
  let(:workflow_class) { require_const("Smith::Workflow") }
  let(:agent_error) { require_const("Smith::AgentError") }
  let(:provider_permanent_failure) { require_const("Smith::ProviderPermanentFailure") }
  let(:workflow_error) { require_const("Smith::WorkflowError") }

  it "succeeds on primary model without invoking fallbacks" do
    agent = with_stubbed_class("SpecFallbackPrimaryAgent", agent_class) do
      register_as :spec_fallback_primary
      model "gpt-5-mini"
      fallback_models model: "gpt-4.1-mini", provider: :openai
    end

    call_count = Concurrent::AtomicFixnum.new(0)
    allow(agent).to receive(:chat) do |**_kwargs|
      call_count.increment
      chat = Object.new
      chat.define_singleton_method(:add_message) { |_| nil }
      chat.define_singleton_method(:with_schema) { |_| self }
      chat.define_singleton_method(:complete) do
        Struct.new(:content, :input_tokens, :output_tokens).new("primary ok", 5, 3)
      end
      chat
    end

    workflow = with_stubbed_class("SpecFallbackPrimaryWorkflow", workflow_class) do
      initial_state :idle
      state :done
      transition :go, from: :idle, to: :done do
        execute :spec_fallback_primary
      end
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
      fallback_models model: "gpt-4.1-mini", provider: :openai
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
        chat.define_singleton_method(:complete) do
          Struct.new(:content, :input_tokens, :output_tokens).new("fallback ok", 5, 3)
        end
      end
      chat
    end

    workflow = with_stubbed_class("SpecFallbackTransientWorkflow", workflow_class) do
      initial_state :idle
      state :done
      state :failed
      transition :go, from: :idle, to: :done do
        execute :spec_fallback_transient
        on_failure :fail
      end
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
        ["openai", "gpt-4.1-mini"] => {
          input_cost_per_token: 0.01,
          output_cost_per_token: 0.02
        }
      }
    end

    agent = with_stubbed_class("SpecFallbackAttemptModelCostAgent", agent_class) do
      register_as :spec_fallback_attempt_model_cost
      model "gpt-5-mini"
      fallback_models model: "gpt-4.1-mini", provider: :openai
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
        ["openai", "gpt-4.1-mini"] => {
          input_cost_per_token: 0.03,
          output_cost_per_token: 0.04
        }
      }
    end

    agent = with_stubbed_class("SpecFallbackKnownUsageAgent", agent_class) do
      register_as :spec_fallback_known_usage
      model "gpt-5-mini"
      fallback_models model: "gpt-4.1-mini", provider: :openai
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
        ["openai", "gpt-4.1-mini"] => {
          input_cost_per_token: 0.01,
          output_cost_per_token: 0.02
        }
      }
    end

    agent = with_stubbed_class("SpecFallbackUnknownUsageAgent", agent_class) do
      register_as :spec_fallback_unknown_usage
      model "gpt-5-mini"
      fallback_models model: "gpt-4.1-mini", provider: :openai
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
      fallback_models model: "gpt-4.1-mini", provider: :openai
    end

    allow(agent).to receive(:chat) do
      chat = Object.new
      chat.define_singleton_method(:add_message) { |_| nil }
      chat.define_singleton_method(:with_schema) { |_| self }
      chat.define_singleton_method(:complete) { raise RubyLLM::ServerError, "all down" }
      chat
    end

    workflow = with_stubbed_class("SpecFallbackExhaustWorkflow", workflow_class) do
      initial_state :idle
      state :done
      state :failed
      transition :go, from: :idle, to: :done do
        execute :spec_fallback_exhaust
        on_failure :fail
      end
    end.new

    result = workflow.run!

    expect(result.state).to eq(:failed)
    expect(result.steps.first[:error]).to be_a(agent_error)
  end

  it "does not fallback on non-transient provider errors" do
    agent = with_stubbed_class("SpecFallbackBadRequestAgent", agent_class) do
      register_as :spec_fallback_bad_request
      model "gpt-5-mini"
      fallback_models model: "gpt-4.1-mini", provider: :openai
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
      initial_state :idle
      state :done
      state :failed
      transition :go, from: :idle, to: :done do
        execute :spec_fallback_bad_request
        on_failure :fail
      end
    end.new

    result = workflow.run!

    expect(result.state).to eq(:failed)
    expect(models_tried).to eq(%w[gpt-5-mini])
    expect(result.last_error).to be_a(provider_permanent_failure)
    expect(Smith::Errors.retryable?(result.last_error)).to be(false)
  end

  it "falls through when the provider reports that the selected model is unavailable" do
    agent = with_stubbed_class("SpecFallbackUnavailableModelAgent", agent_class) do
      register_as :spec_fallback_unavailable_model
      model "retired-primary"
      fallback_models model: "available-fallback", provider: :openai
    end

    models_tried = []
    allow(agent).to receive(:chat) do |**kwargs|
      model = kwargs[:model] || "retired-primary"
      models_tried << model
      chat = Object.new
      chat.define_singleton_method(:add_message) { |_| nil }
      chat.define_singleton_method(:with_schema) { |_| self }
      if model == "retired-primary"
        chat.define_singleton_method(:complete) do
          error = RubyLLM::Error.new("model is unavailable")
          error.define_singleton_method(:response) { Struct.new(:status).new(404) }
          raise error
        end
      else
        chat.define_singleton_method(:complete) do
          Struct.new(:content, :input_tokens, :output_tokens).new("fallback ok", 5, 3)
        end
      end
      chat
    end

    workflow = with_stubbed_class("SpecFallbackUnavailableModelWorkflow", workflow_class) do
      initial_state :idle
      state :done
      state :failed
      transition :go, from: :idle, to: :done do
        execute :spec_fallback_unavailable_model
        on_failure :fail
      end
    end.new

    result = workflow.run!

    expect(result.state).to eq(:done)
    expect(result.output).to eq("fallback ok")
    expect(models_tried).to eq(%w[retired-primary available-fallback])
  end

  it "does not start a fallback chat after graceful tool evidence has been consumed" do
    agent = with_stubbed_class("SpecFallbackAfterToolAgent", agent_class) do
      register_as :spec_fallback_after_tool
      model "gpt-5-mini"
      fallback_models model: "gpt-4.1-mini", provider: :openai
      budget tool_calls: 1
      tool_budget_exhaustion :complete
    end
    tool = Class.new(Smith::Tool) do
      def perform(**)
        "captured evidence"
      end
    end.new

    models_tried = []
    allow(agent).to receive(:chat) do |**kwargs|
      model = kwargs[:model] || "gpt-5-mini"
      models_tried << model
      Object.new.tap do |chat|
        chat.define_singleton_method(:add_message) { |_| nil }
        chat.define_singleton_method(:complete) do
          tool.execute if model == "gpt-5-mini"
          raise RubyLLM::ServerError, "synthesis unavailable"
        end
      end
    end

    workflow = with_stubbed_class("SpecFallbackAfterToolWorkflow", workflow_class) do
      initial_state :idle
      state :done
      state :failed
      transition :go, from: :idle, to: :done do
        execute :spec_fallback_after_tool
        on_failure :fail
      end
    end.new

    result = workflow.run!

    expect(result.state).to eq(:failed)
    expect(models_tried).to eq(["gpt-5-mini"])
    expect(result.last_error).to be_a(Smith::ToolOutcomeUncertain)
    expect(result.last_error.message).to include("could replay an uncertain outcome")
  end

  it "does not invent outcome uncertainty when a tool is rejected before perform" do
    agent = with_stubbed_class("SpecFallbackAfterRejectedDispatchAgent", agent_class) do
      register_as :spec_fallback_after_rejected_dispatch
      model "gpt-5-mini"
      fallback_models model: "gpt-4.1-mini", provider: :openai
    end
    dispatches = 0
    tool = Class.new(Smith::Tool) do
      before_execute do
        dispatches += 1
        raise "pre-execution policy unavailable"
      end

      def perform(**) = raise("must not perform")
    end.new
    models_tried = []
    allow(agent).to receive(:chat) do |**kwargs|
      models_tried << (kwargs[:model] || "gpt-5-mini")
      Object.new.tap do |chat|
        chat.define_singleton_method(:add_message) { |_| nil }
        chat.define_singleton_method(:complete) do
          tool.execute
        rescue RuntimeError => e
          raise unless e.message == "pre-execution policy unavailable"

          raise RubyLLM::BadRequestError, "provider rejected the continuation"
        end
      end
    end
    workflow = with_stubbed_class("SpecFallbackAfterRejectedDispatchWorkflow", workflow_class) do
      initial_state :idle
      state :done
      state :failed
      transition :go, from: :idle, to: :done do
        execute :spec_fallback_after_rejected_dispatch
        on_failure :fail
      end
    end.new

    result = workflow.run!

    expect(result.state).to eq(:failed)
    expect(result.last_error).to be_a(Smith::ProviderPermanentFailure)
    expect(result.last_error).not_to be_a(Smith::ToolOutcomeUncertain)
    expect(result.last_error.message).to eq("provider rejected the continuation")
    expect(models_tried).to eq(["gpt-5-mini"])
    expect(dispatches).to eq(1)
  end

  it "blocks fallback after a plain RubyLLM tool dispatch" do
    agent = with_stubbed_class("SpecFallbackAfterPlainToolAgent", agent_class) do
      register_as :spec_fallback_after_plain_tool
      model "gpt-5-mini"
      fallback_models model: "gpt-4.1-mini", provider: :openai
    end
    executions = 0
    tool = Class.new(RubyLLM::Tool) do
      define_method(:name) { "plain_fallback_probe" }
      define_method(:execute) do
        executions += 1
        "external result"
      end
    end.new
    context = RubyLLM.context { |config| config.openai_api_key = "test" }
    tool_call = RubyLLM::ToolCall.new(id: "plain-1", name: :plain_fallback_probe, arguments: {})
    responses = [
      RubyLLM::Message.new(role: :assistant, content: nil, tool_calls: { "plain-1" => tool_call }),
      RubyLLM::ServerError.new("synthesis unavailable")
    ]
    models_tried = []
    allow(agent).to receive(:chat) do |**kwargs|
      models_tried << (kwargs[:model] || "gpt-5-mini")
      chat = SpecBoundedRubyLLMChat.new(responses:, context:).with_tool(tool)
      Smith::Tool::ChatExecutionContext.install(chat)
    end

    workflow = with_stubbed_class("SpecFallbackAfterPlainToolWorkflow", workflow_class) do
      initial_state :idle
      state :done
      state :failed
      transition :go, from: :idle, to: :done do
        execute :spec_fallback_after_plain_tool
        on_failure :fail
      end
    end.new

    result = workflow.run!

    expect(result.state).to eq(:failed)
    expect(result.last_error).to be_a(Smith::ToolOutcomeUncertain)
    expect(models_tried).to eq(["gpt-5-mini"])
    expect(executions).to eq(1)
  end

  it "accounts for successful provider rounds before a later round fails" do
    agent = with_stubbed_class("SpecPartialUsageAgent", agent_class) do
      register_as :spec_partial_usage
      model "gpt-5-mini"
    end
    message = Struct.new(:role, :content, :input_tokens, :output_tokens).new(:assistant, nil, 11, 7)
    messages = []
    allow(agent).to receive(:chat) do
      Object.new.tap do |chat|
        chat.define_singleton_method(:messages) { messages }
        chat.define_singleton_method(:add_message) { |value| messages << value }
        chat.define_singleton_method(:complete) do
          messages << message
          raise RubyLLM::ServerError, "later round failed"
        end
      end
    end

    workflow = with_stubbed_class("SpecPartialUsageWorkflow", workflow_class) do
      initial_state :idle
      state :done
      state :failed
      transition :go, from: :idle, to: :done do
        execute :spec_partial_usage
        on_failure :fail
      end
    end.new

    result = workflow.run!

    expect(result.state).to eq(:failed)
    expect(result.total_tokens).to eq(18)
    expect(result.usage_entries.map(&:attempt_kind)).to eq([:partial_attempt])
  end

  it "does not fallback on Smith::Error subclasses" do
    with_stubbed_class("SpecFallbackSmithErrorAgent", agent_class) do
      register_as :spec_fallback_smith_error
      model "gpt-5-mini"
      fallback_models model: "gpt-4.1-mini", provider: :openai
    end

    workflow = with_stubbed_class("SpecFallbackSmithErrorWorkflow", workflow_class) do
      initial_state :idle
      state :done
      state :failed
      budget wall_clock: 0
      transition :go, from: :idle, to: :done do
        execute :spec_fallback_smith_error
        on_failure :fail
      end
    end.new

    sleep 0.01
    result = workflow.run!

    expect(result.state).to eq(:failed)
    expect(result.steps.first[:error]).to be_a(Smith::DeadlineExceeded)
  end

  it "inherits fallback_models in subclasses" do
    parent = with_stubbed_class("SpecFallbackParentAgent", agent_class) do
      model "gpt-5-mini"
      fallback_models(
        { model: "gpt-4.1-mini", provider: :openai },
        { model: "gpt-4.1-nano", provider: :openai }
      )
    end

    child = Class.new(parent)

    expect(child.fallback_models.map(&:to_h)).to eq(
      [
        { model_id: "gpt-4.1-mini", provider: :openai },
        { model_id: "gpt-4.1-nano", provider: :openai }
      ]
    )
    expect(child.fallback_models).to be_frozen
    expect do
      child.fallback_models << Smith::Agent::ModelReference.coerce(
        { model: "another-fallback", provider: :openai }
      )
    end.to raise_error(FrozenError)
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
      initial_state :idle
      state :done
      transition :go, from: :idle, to: :done do
        execute :spec_fallback_none
      end
    end.new

    result = workflow.run!

    expect(result.state).to eq(:done)
    expect(result.output).to eq("ok")
  end

  it "attributes a legacy unqualified primary to the provider resolved by RubyLLM" do
    agent = with_stubbed_class("SpecObservedPrimaryProviderAgent", agent_class) do
      register_as :spec_observed_primary_provider
      model "shared-model"
    end

    allow(agent).to receive(:chat) do
      chat = Object.new
      chat.define_singleton_method(:model) do
        Struct.new(:id, :provider).new("shared-model", "anthropic")
      end
      chat.define_singleton_method(:add_message) { |_| nil }
      chat.define_singleton_method(:with_schema) { |_| self }
      chat.define_singleton_method(:messages) { [] }
      chat.define_singleton_method(:complete) do
        Struct.new(:role, :content, :input_tokens, :output_tokens)
              .new(:assistant, "ok", 5, 3)
      end
      chat
    end

    workflow = with_stubbed_class("SpecObservedPrimaryProviderWorkflow", workflow_class) do
      initial_state :idle
      state :done
      transition :go, from: :idle, to: :done do
        execute :spec_observed_primary_provider
      end
    end.new

    result = workflow.run!

    expect(result.state).to eq(:done)
    expect(result.usage_entries.sole.model).to eq("shared-model")
    expect(result.usage_entries.sole.provider).to eq(:anthropic)
  end

  it "deduplicates fallback_models while preserving order" do
    agent = with_stubbed_class("SpecFallbackDedupAgent", agent_class) do
      model "gpt-5-mini"
      fallback_models(
        { model: "gpt-4.1-mini", provider: :openai },
        { model: "gpt-4.1-nano", provider: :openai },
        { model: "gpt-4.1-mini", provider: :openai }
      )
    end

    expect(agent.fallback_models.map(&:to_h)).to eq(
      [
        { model_id: "gpt-4.1-mini", provider: :openai },
        { model_id: "gpt-4.1-nano", provider: :openai }
      ]
    )
  end

  it "keeps provider identity scoped to each fallback attempt" do
    agent = with_stubbed_class("SpecProviderQualifiedFallbackAgent", agent_class) do
      model "shared-primary", provider: :openai
      fallback_models(
        { model: "claude-sonnet-fallback", provider: :anthropic },
        { model: "shared-fallback", provider: :openrouter }
      )
    end
    workflow = workflow_class.new

    chain = workflow.send(:build_model_chain, agent)

    expect(chain.map(&:to_h)).to eq(
      [
        { model_id: "shared-primary", provider: :openai },
        { model_id: "claude-sonnet-fallback", provider: :anthropic },
        { model_id: "shared-fallback", provider: :openrouter }
      ]
    )
  end

  it "rejects blank fallback model entries" do
    expect do
      with_stubbed_class("SpecFallbackBlankModelAgent", agent_class) do
        model "gpt-5-mini"
        fallback_models(
          { model: "", provider: :openai },
          { model: "gpt-4.1-mini", provider: :openai }
        )
      end
    end.to raise_error(workflow_error, /must not be blank/)
  end

  it "rejects provider-unqualified fallback models" do
    expect do
      with_stubbed_class("SpecFallbackUnqualifiedAgent", agent_class) do
        model "gpt-5-mini", provider: :openai
        fallback_models "gpt-4.1-mini"
      end
    end.to raise_error(workflow_error, /must include an explicit provider/)
  end

  it "skips only the failed provider after an account-scoped failure" do
    agent = with_stubbed_class("SpecProviderAccountFallbackAgent", agent_class) do
      register_as :spec_provider_account_fallback
      model "shared-primary", provider: :openai
      fallback_models(
        { model: "same-account-fallback", provider: :openai },
        { model: "other-provider-fallback", provider: :anthropic }
      )
    end
    attempts = []

    allow(agent).to receive(:chat) do |**kwargs|
      attempts << kwargs.values_at(:provider, :model)
      chat = Object.new
      chat.define_singleton_method(:add_message) { |_| nil }
      chat.define_singleton_method(:with_schema) { |_| self }
      if kwargs[:provider] == :openai
        chat.define_singleton_method(:complete) do
          raise RubyLLM::UnauthorizedError, "invalid OpenAI credentials"
        end
      else
        chat.define_singleton_method(:complete) do
          Struct.new(:content, :input_tokens, :output_tokens).new("anthropic ok", 5, 3)
        end
      end
      chat
    end

    workflow = with_stubbed_class("SpecProviderAccountFallbackWorkflow", workflow_class) do
      initial_state :idle
      state :done
      state :failed
      transition :go, from: :idle, to: :done do
        execute :spec_provider_account_fallback
        on_failure :fail
      end
    end.new

    result = workflow.run!

    expect(result.state).to eq(:done)
    expect(result.output).to eq("anthropic ok")
    expect(attempts).to eq(
      [
        [:openai, "shared-primary"],
        [:anthropic, "other-provider-fallback"]
      ]
    )
  end

  it "uses the observed primary provider to skip account-scoped fallbacks" do
    agent = with_stubbed_class("SpecObservedProviderAccountFallbackAgent", agent_class) do
      register_as :spec_observed_provider_account_fallback
      model "shared-primary"
      fallback_models(
        { model: "same-account-fallback", provider: :openai },
        { model: "other-provider-fallback", provider: :anthropic }
      )
    end
    attempts = []

    allow(agent).to receive(:chat) do |**kwargs|
      attempts << kwargs.values_at(:provider, :model)
      chat = Object.new
      chat.define_singleton_method(:model) do
        provider = kwargs[:provider] || :openai
        Struct.new(:id, :provider).new(kwargs.fetch(:model), provider.to_s)
      end
      chat.define_singleton_method(:add_message) { |_| nil }
      chat.define_singleton_method(:with_schema) { |_| self }
      if kwargs[:model] == "shared-primary"
        chat.define_singleton_method(:complete) do
          raise RubyLLM::UnauthorizedError, "invalid OpenAI credentials"
        end
      else
        chat.define_singleton_method(:complete) do
          Struct.new(:content, :input_tokens, :output_tokens).new("anthropic ok", 5, 3)
        end
      end
      chat
    end

    workflow = with_stubbed_class("SpecObservedProviderAccountFallbackWorkflow", workflow_class) do
      initial_state :idle
      state :done
      state :failed
      transition :go, from: :idle, to: :done do
        execute :spec_observed_provider_account_fallback
        on_failure :fail
      end
    end.new

    result = workflow.run!

    expect(result.state).to eq(:done)
    expect(result.output).to eq("anthropic ok")
    expect(attempts).to eq(
      [
        [nil, "shared-primary"],
        [:anthropic, "other-provider-fallback"]
      ]
    )
  end

  it "keeps same-provider fallbacks available after a model-scoped forbidden response" do
    agent = with_stubbed_class("SpecProviderForbiddenFallbackAgent", agent_class) do
      register_as :spec_provider_forbidden_fallback
      model "restricted-primary", provider: :openai
      fallback_models(
        { model: "permitted-fallback", provider: :openai },
        { model: "other-provider-fallback", provider: :anthropic }
      )
    end
    attempts = []

    allow(agent).to receive(:chat) do |**kwargs|
      attempts << kwargs.values_at(:provider, :model)
      chat = Object.new
      chat.define_singleton_method(:model) do
        Struct.new(:id, :provider).new(kwargs.fetch(:model), kwargs.fetch(:provider).to_s)
      end
      chat.define_singleton_method(:add_message) { |_| nil }
      chat.define_singleton_method(:with_schema) { |_| self }
      if kwargs[:model] == "restricted-primary"
        chat.define_singleton_method(:complete) do
          raise RubyLLM::ForbiddenError, "model access denied"
        end
      else
        chat.define_singleton_method(:complete) do
          Struct.new(:content, :input_tokens, :output_tokens).new("same provider ok", 5, 3)
        end
      end
      chat
    end

    workflow = with_stubbed_class("SpecProviderForbiddenFallbackWorkflow", workflow_class) do
      initial_state :idle
      state :done
      state :failed
      transition :go, from: :idle, to: :done do
        execute :spec_provider_forbidden_fallback
        on_failure :fail
      end
    end.new

    result = workflow.run!

    expect(result.state).to eq(:done)
    expect(result.output).to eq("same provider ok")
    expect(attempts).to eq(
      [
        [:openai, "restricted-primary"],
        [:openai, "permitted-fallback"]
      ]
    )
  end

  it "does not reinterpret programming errors as provider failures" do
    agent = with_stubbed_class("SpecProviderProgrammingErrorAgent", agent_class) do
      register_as :spec_provider_programming_error
      model "primary", provider: :openai
      fallback_models model: "fallback", provider: :anthropic
    end
    attempts = []

    allow(agent).to receive(:chat) do |**kwargs|
      attempts << kwargs.values_at(:provider, :model)
      chat = Object.new
      chat.define_singleton_method(:add_message) { |_| nil }
      chat.define_singleton_method(:with_schema) { |_| self }
      chat.define_singleton_method(:complete) { raise NoMethodError, "broken provider integration" }
      chat
    end

    workflow = workflow_class.new

    expect do
      workflow.send(
        :complete_with_provider,
        agent,
        [{ role: :user, content: "input" }],
        output_schema: nil
      )
    end.to raise_error(NoMethodError, /broken provider integration/)
    expect(attempts).to eq([[:openai, "primary"]])
  end

  it "isolates configured model identity from mutable caller strings" do
    model_id = String.new("mutable-model")
    provider = String.new("openai")
    agent = with_stubbed_class("SpecImmutableFallbackReferenceAgent", agent_class) do
      fallback_models model: model_id, provider: provider
    end

    model_id.replace("changed-model")
    provider.replace("anthropic")

    expect(agent.fallback_models.first.to_h).to eq(
      model_id: "mutable-model",
      provider: :openai
    )
    expect(agent.fallback_models.first).to be_frozen
    expect(agent.fallback_models.first.model_id).to be_frozen
  end

  it "accepts the provider/model string form for fallback declarations" do
    agent = with_stubbed_class("SpecSlashedFallbackAgent", agent_class) do
      model "gpt-5-mini"
      fallback_models "openai/gpt-4.1-mini"
    end

    expect(agent.fallback_models.map(&:to_h)).to eq(
      [{ model_id: "gpt-4.1-mini", provider: :openai }]
    )
  end

  it "skips only the failed provider after a payment-required account failure" do
    agent = with_stubbed_class("SpecProviderPaymentFallbackAgent", agent_class) do
      register_as :spec_provider_payment_fallback
      model "shared-primary", provider: :openai
      fallback_models(
        { model: "same-account-fallback", provider: :openai },
        { model: "other-provider-fallback", provider: :anthropic }
      )
    end
    attempts = []

    allow(agent).to receive(:chat) do |**kwargs|
      attempts << kwargs.values_at(:provider, :model)
      chat = Object.new
      chat.define_singleton_method(:add_message) { |_| nil }
      chat.define_singleton_method(:with_schema) { |_| self }
      if kwargs[:provider] == :openai
        chat.define_singleton_method(:complete) do
          raise RubyLLM::PaymentRequiredError, "OpenAI account balance exhausted"
        end
      else
        chat.define_singleton_method(:complete) do
          Struct.new(:content, :input_tokens, :output_tokens).new("anthropic ok", 5, 3)
        end
      end
      chat
    end

    workflow = with_stubbed_class("SpecProviderPaymentFallbackWorkflow", workflow_class) do
      initial_state :idle
      state :done
      state :failed
      transition :go, from: :idle, to: :done do
        execute :spec_provider_payment_fallback
        on_failure :fail
      end
    end.new

    result = workflow.run!

    expect(result.state).to eq(:done)
    expect(result.output).to eq("anthropic ok")
    expect(attempts).to eq(
      [
        [:openai, "shared-primary"],
        [:anthropic, "other-provider-fallback"]
      ]
    )
  end

  it "suppresses via the attempted reference's provider when the observed provider is unknown" do
    workflow = workflow_class.new
    attempt = Smith::Agent::ProviderAttempt.failure(
      error: RubyLLM::UnauthorizedError.new("invalid credentials"),
      model_reference: Smith::Agent::ModelReference.new(model_id: "shared-primary", provider: nil)
    )
    attempted = Smith::Agent::ModelReference.new(model_id: "shared-primary", provider: :openai)

    expect(workflow.send(:account_failed_provider, attempt, attempted)).to eq(:openai)
  end

  it "does not attribute a non-account failure to any provider" do
    workflow = workflow_class.new
    attempt = Smith::Agent::ProviderAttempt.failure(
      error: RubyLLM::ServerError.new("transient"),
      model_reference: Smith::Agent::ModelReference.new(model_id: "shared-primary", provider: :openai)
    )
    attempted = Smith::Agent::ModelReference.new(model_id: "shared-primary", provider: :openai)

    expect(workflow.send(:account_failed_provider, attempt, attempted)).to be_nil
  end

  it "fails closed with a typed error when no model candidate is configured" do
    agent = with_stubbed_class("SpecEmptyChainAgent", agent_class) do
      register_as :spec_empty_chain
    end
    workflow = workflow_class.new

    expect do
      workflow.send(:invoke_agent, agent, nil, output_schema: nil)
    end.to raise_error(agent_error, /no executable model candidate/)
  end

  it "collapses an unqualified primary and a qualified fallback of the same model into one candidate" do
    agent = with_stubbed_class("SpecPhysicalDedupAgent", agent_class) do
      model "gpt-5-mini"
      fallback_models(
        { model: "gpt-5-mini", provider: :openai },
        { model: "gpt-4.1-nano", provider: :openai }
      )
    end
    workflow = workflow_class.new

    chain = workflow.send(:build_model_chain, agent)

    expect(chain.map(&:to_h)).to eq(
      [
        { model_id: "gpt-5-mini", provider: nil },
        { model_id: "gpt-4.1-nano", provider: :openai }
      ]
    )
  end

  it "finalizes a successful completion with unpriced usage when the catalog only has a legacy key" do
    original_pricing = Smith.config.pricing

    Smith.configure do |config|
      config.pricing = {
        "legacy-priced-model" => { input_cost_per_token: 0.01, output_cost_per_token: 0.02 }
      }
    end

    agent = with_stubbed_class("SpecLegacyCatalogSuccessAgent", agent_class) do
      register_as :spec_legacy_catalog_success
      model "legacy-priced-model"
    end

    allow(agent).to receive(:chat) do
      chat = Object.new
      chat.define_singleton_method(:model) { Struct.new(:id, :provider).new("legacy-priced-model", "openai") }
      chat.define_singleton_method(:add_message) { |_| nil }
      chat.define_singleton_method(:with_schema) { |_| self }
      chat.define_singleton_method(:messages) { [] }
      chat.define_singleton_method(:complete) do
        Struct.new(:role, :content, :input_tokens, :output_tokens).new(:assistant, "ok", 5, 3)
      end
      chat
    end

    workflow = with_stubbed_class("SpecLegacyCatalogSuccessWorkflow", workflow_class) do
      initial_state :idle
      state :done
      state :failed
      transition :go, from: :idle, to: :done do
        execute :spec_legacy_catalog_success
        on_failure :fail
      end
    end.new

    result = workflow.run!

    expect(result.state).to eq(:done)
    expect(result.output).to eq("ok")
    entry = result.usage_entries.sole
    expect(entry.attempt_kind).to eq(:completed_attempt)
    expect(entry.provider).to eq(:openai)
    expect(entry.cost).to be_nil
  ensure
    Smith.configure { |config| config.pricing = original_pricing }
  end

  it "preserves the provider error and fallback eligibility when failure accounting is unpriced" do
    original_pricing = Smith.config.pricing

    Smith.configure do |config|
      config.pricing = {
        "shared-primary" => { input_cost_per_token: 0.01, output_cost_per_token: 0.02 }
      }
    end

    agent = with_stubbed_class("SpecLegacyCatalogFailureAgent", agent_class) do
      register_as :spec_legacy_catalog_failure
      model "shared-primary", provider: :openai
      fallback_models model: "other-provider-fallback", provider: :anthropic
    end
    attempts = []

    allow(agent).to receive(:chat) do |**kwargs|
      attempts << kwargs.values_at(:provider, :model)
      chat = Object.new
      chat.define_singleton_method(:add_message) { |_| nil }
      chat.define_singleton_method(:with_schema) { |_| self }
      if kwargs[:provider] == :openai
        chat.define_singleton_method(:complete) do
          error = RubyLLM::ServerError.new("provider exploded")
          error.define_singleton_method(:input_tokens) { 10 }
          error.define_singleton_method(:output_tokens) { 5 }
          raise error
        end
      else
        chat.define_singleton_method(:complete) do
          Struct.new(:content, :input_tokens, :output_tokens).new("anthropic ok", 5, 3)
        end
      end
      chat
    end

    workflow = with_stubbed_class("SpecLegacyCatalogFailureWorkflow", workflow_class) do
      initial_state :idle
      state :done
      state :failed
      transition :go, from: :idle, to: :done do
        execute :spec_legacy_catalog_failure
        on_failure :fail
      end
    end.new

    result = workflow.run!

    expect(result.state).to eq(:done)
    expect(result.output).to eq("anthropic ok")
    expect(attempts).to eq(
      [
        [:openai, "shared-primary"],
        [:anthropic, "other-provider-fallback"]
      ]
    )
    failed_entry = result.usage_entries.find { |entry| entry.attempt_kind == :failed_attempt }
    expect(failed_entry.provider).to eq(:openai)
    expect(failed_entry.cost).to be_nil
  ensure
    Smith.configure { |config| config.pricing = original_pricing }
  end

  it "records completed-prefix and failed-round usage as disjoint provider rounds" do
    # RubyLLM appends only completed assistant rounds to the chat; the
    # failing request's usage arrives solely on the raised error, so the
    # :partial_attempt and :failed_attempt entries never cover the same
    # provider round and no dedupe is required.
    agent = with_stubbed_class("SpecPartialPlusFailedUsageAgent", agent_class) do
      register_as :spec_partial_plus_failed_usage
      model "gpt-5-mini"
    end
    prefix_message = Struct.new(:role, :content, :input_tokens, :output_tokens).new(:assistant, nil, 2, 3)
    messages = []
    allow(agent).to receive(:chat) do
      Object.new.tap do |chat|
        chat.define_singleton_method(:messages) { messages }
        chat.define_singleton_method(:add_message) { |value| messages << value }
        chat.define_singleton_method(:complete) do
          messages << prefix_message
          error = RubyLLM::ServerError.new("final round failed")
          error.define_singleton_method(:input_tokens) { 10 }
          error.define_singleton_method(:output_tokens) { 5 }
          raise error
        end
      end
    end

    workflow = with_stubbed_class("SpecPartialPlusFailedUsageWorkflow", workflow_class) do
      initial_state :idle
      state :done
      state :failed
      transition :go, from: :idle, to: :done do
        execute :spec_partial_plus_failed_usage
        on_failure :fail
      end
    end.new

    result = workflow.run!

    expect(result.state).to eq(:failed)
    expect(result.usage_entries.map(&:attempt_kind)).to eq(%i[partial_attempt failed_attempt])
    expect(result.total_tokens).to eq(20)
  end
end
