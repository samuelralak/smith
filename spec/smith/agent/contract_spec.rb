# frozen_string_literal: true

RSpec.describe "Smith::Agent contract" do
  let(:agent_class) { require_const("Smith::Agent") }

  it "extends RubyLLM::Agent rather than replacing it" do
    expect(agent_class).to be < RubyLLM::Agent
  end

  it "exposes the documented Smith DSL additions" do
    %i[budget guardrails output_schema data_volume register_as tool_budget_exhaustion].each do |dsl|
      expect(agent_class).to respond_to(dsl), "expected Smith::Agent to implement .#{dsl}"
    end
  end

  it "defaults tool-budget exhaustion to raising and inherits explicit completion policy" do
    parent = Class.new(agent_class) do
      tool_budget_exhaustion :complete
    end
    child = Class.new(parent)

    expect(agent_class.tool_budget_exhaustion).to eq(:raise)
    expect(parent.tool_budget_exhaustion).to eq(:complete)
    expect(child.tool_budget_exhaustion).to eq(:complete)
  end

  it "accepts every agent budget key Smith reads" do
    concrete = Class.new(agent_class) do
      budget token_limit: 10, cost: 0.1, wall_clock: 5, tool_calls: 2, total_tokens: 10, total_cost: 0.1
    end

    expect(concrete.budget.keys).to eq(%i[token_limit cost wall_clock tool_calls total_tokens total_cost])
  end

  it "rejects an agent budget key Smith does not read, naming the accepted keys" do
    expect do
      Class.new(agent_class) { budget token_limit: 10, wall_clock_ms: 5_000 }
    end.to raise_error(
      ArgumentError,
      "agent budget does not accept :wall_clock_ms; " \
      "accepted keys are :token_limit, :cost, :wall_clock, :tool_calls, :total_tokens, :total_cost"
    )
  end

  it "rejects unknown tool-budget exhaustion policies" do
    expect do
      Class.new(agent_class) { tool_budget_exhaustion :retry }
    end.to raise_error(ArgumentError, "tool_budget_exhaustion must be :raise or :complete")
  end

  it "retains the RubyLLM agent class API surface" do
    %i[chat_model model tools instructions temperature thinking schema find create create! chat].each do |dsl|
      expect(agent_class).to respond_to(dsl), "expected Smith::Agent to retain RubyLLM .#{dsl}"
    end
  end

  it "allows a concrete Smith agent class to be declared with the documented DSL" do
    concrete = with_stubbed_class("SpecResearchAgent", agent_class) do
      chat_model Class.new
      model "gpt-5-mini"
      tools
      temperature 0.3
      budget token_limit: 100_000, tool_calls: 20
      output_schema Class.new
      data_volume :unbounded
      instructions do |context|
        context[:system_prompt]
      end
      guardrails Class.new
      register_as :spec_research_agent
    end

    expect(concrete).to be < agent_class
  end
end
