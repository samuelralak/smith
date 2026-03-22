# frozen_string_literal: true

RSpec.describe "Smith::Workflow context persistence contract" do
  let(:workflow_class) { require_const("Smith::Workflow") }
  let(:context_class) { require_const("Smith::Context") }
  let(:agent_class) { require_const("Smith::Agent") }

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

  it "round-trips persisted session history alongside persisted workflow context" do
    agent = with_stubbed_class("SpecPersistedSessionHistoryAgent", agent_class) do
      register_as :spec_persisted_session_history_agent
      model "gpt-5-mini"
    end

    fake_chat = Object.new
    fake_chat.define_singleton_method(:add_message) { |_message| nil }
    fake_chat.define_singleton_method(:complete) do
      Struct.new(:content).new("accepted")
    end

    allow(agent).to receive(:chat).and_return(fake_chat)

    manager = with_stubbed_class("SpecPersistedSessionHistoryContext", context_class) do
      persist :current_findings
      inject_state do |persisted|
        "summary: #{persisted[:current_findings]}"
      end
    end

    workflow_class_with_context = with_stubbed_class("SpecPersistedSessionHistoryWorkflow", workflow_class) do
      initial_state :idle
      state :done
      context_manager manager

      transition :finish, from: :idle, to: :done do
        execute :spec_persisted_session_history_agent
      end
    end

    workflow = workflow_class_with_context.new(context: { current_findings: "kept", ignored: "drop" })
    workflow.instance_variable_set(:@session_messages, [{ role: :user, content: "latest" }])

    workflow.run!
    state = workflow.to_state
    restored = workflow_class_with_context.from_state(state)

    expect(state[:context]).to eq(current_findings: "kept")
    expect(state[:session_messages]).to eq(
      [
        { role: :user, content: "latest" },
        { role: :system, content: "[smith:injected-state]\nsummary: kept" },
        { role: :assistant, content: "accepted" }
      ]
    )
    expect(restored.to_state[:session_messages]).to eq(state[:session_messages])
  end
end
