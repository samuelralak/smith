# frozen_string_literal: true

RSpec.describe "workflow pattern contract" do
  let(:workflow_class) { require_const("Smith::Workflow") }

  it "defines helper namespaces for pipeline, router, and parallel workflow patterns" do
    %w[
      Smith::Workflow::Pipeline
      Smith::Workflow::Router
      Smith::Workflow::Parallel
    ].each do |path|
      expect(fetch_const(path)).not_to be_nil, "expected #{path} to be defined"
    end
  end

  it "keeps orchestrator-worker support bounded by workflow transition limits" do
    expect(workflow_class).to respond_to(:max_transitions)
  end
end
