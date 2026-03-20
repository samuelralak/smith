# frozen_string_literal: true

RSpec.describe "Smith::Agent contract" do
  let(:agent_class) { require_const("Smith::Agent") }

  it "extends RubyLLM::Agent rather than replacing it" do
    expect(agent_class).to be < RubyLLM::Agent
  end

  it "exposes the documented Smith DSL additions" do
    %i[budget guardrails output_schema data_volume register_as].each do |dsl|
      expect(agent_class).to respond_to(dsl), "expected Smith::Agent to implement .#{dsl}"
    end
  end

  it "retains the RubyLLM agent class API surface" do
    %i[chat_model model tools instructions temperature thinking schema find create chat].each do |dsl|
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
