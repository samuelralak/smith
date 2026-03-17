# frozen_string_literal: true

RSpec.describe "Smith::Agent registry contract" do
  let(:registry) { require_const("Smith::Agent::Registry") }
  let(:agent_class) { require_const("Smith::Agent") }

  it "provides a registry namespace used by workflow execute bindings" do
    expect(registry).not_to be_nil
    expect(registry).to respond_to(:find)
  end

  it "supports explicit registration names via register_as" do
    concrete = with_stubbed_class("SpecRegisteredAgent", agent_class) do
      register_as :spec_registered_agent
    end

    expect(concrete).to be < agent_class
  end
end
