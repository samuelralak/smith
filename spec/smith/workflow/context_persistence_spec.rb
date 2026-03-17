# frozen_string_literal: true

RSpec.describe "Smith::Workflow context persistence contract" do
  let(:workflow_class) { require_const("Smith::Workflow") }
  let(:context_class) { require_const("Smith::Context") }

  it "serializes only the context keys declared by the workflow's context manager" do
    manager = with_stubbed_class("SpecPersistedContextManager", context_class) do
      persist :current_findings, :source_urls
    end

    workflow = with_stubbed_class("SpecPersistedContextWorkflow", workflow_class) do
      initial_state :idle
      context_manager manager
    end.new(
      context: {
        current_findings: "stable",
        source_urls: ["https://example.com"],
        user_context: { role: "editor" }
      }
    )

    expect(workflow.to_state[:context]).to eq(
      current_findings: "stable",
      source_urls: ["https://example.com"]
    )
  end

  it "restores only the persisted context keys from serialized state" do
    manager = with_stubbed_class("SpecRestoredContextManager", context_class) do
      persist :current_findings
    end

    workflow_class_with_context = with_stubbed_class("SpecRestoredContextWorkflow", workflow_class) do
      initial_state :idle
      context_manager manager
    end

    restored = workflow_class_with_context.from_state(
      class: "SpecRestoredContextWorkflow",
      state: :idle,
      context: {
        current_findings: "kept",
        source_urls: ["https://ignored.example"]
      },
      budget_consumed: {},
      step_count: 0,
      created_at: "2026-03-18T00:00:00Z",
      updated_at: "2026-03-18T00:00:00Z"
    )

    expect(restored.to_state[:context]).to eq(current_findings: "kept")
  end
end
