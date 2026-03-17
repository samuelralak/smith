# frozen_string_literal: true

RSpec.describe "Smith::Context contract" do
  let(:context_class) { require_const("Smith::Context") }
  let(:workflow_class) { require_const("Smith::Workflow") }

  it "provides the documented context DSL" do
    %i[session_strategy persist inject_state].each do |dsl|
      expect(context_class).to respond_to(dsl), "expected Smith::Context to implement .#{dsl}"
    end
  end

  it "can be attached at workflow level" do
    manager = with_stubbed_class("SpecResearchContext", context_class) do
      session_strategy :observation_masking, window: 10
      persist :current_findings, :source_urls
      inject_state { |persisted| persisted.inspect }
    end

    workflow = with_stubbed_class("SpecContextWorkflow", workflow_class) do
      context_manager manager
    end

    expect(workflow).to be < workflow_class
  end
end
