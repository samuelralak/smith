# frozen_string_literal: true

require "json"

RSpec.describe "Smith::Workflow state serialization shape" do
  let(:workflow_class) { require_const("Smith::Workflow") }

  it "serializes to the documented state hash shape" do
    workflow = with_stubbed_class("SpecStateWorkflow", workflow_class) do
      initial_state :idle
    end.new(context: { branch_count: 6, metadata: { topic: "history" } })

    state = workflow.to_state

    expect(state.keys).to eq(%i[class state context budget_consumed step_count execution_namespace created_at updated_at])
    expect(state[:class]).to eq("SpecStateWorkflow")
    expect(state[:state]).to eq(:idle)
    expect(state[:context]).to eq(branch_count: 6, metadata: { topic: "history" })
    expect(state[:budget_consumed]).to be_a(Hash)
    expect(state[:step_count]).to be_a(Integer)
    expect(state[:created_at]).to be_a(String)
    expect(state[:updated_at]).to be_a(String)
  end

  it "round-trips through from_state without serializing agent instances" do
    workflow = with_stubbed_class("SpecRoundTripWorkflow", workflow_class) do
      initial_state :idle
    end.new(context: { branch_count: 3 })

    restored = workflow.class.from_state(workflow.to_state)

    expect(restored.to_state).to eq(workflow.to_state)
    expect(JSON.generate(restored.to_state)).to be_a(String)
  end

  it "preserves the execution namespace across serialization after workflow execution" do
    agent_class = require_const("Smith::Agent")

    agent = with_stubbed_class("SpecExecutionNamespaceAgent", agent_class) do
      register_as :spec_execution_namespace_agent
      model "gpt-5-mini"
    end

    fake_chat = Object.new
    fake_chat.define_singleton_method(:add_message) { |_message| nil }
    fake_chat.define_singleton_method(:complete) do
      Struct.new(:content).new("ok")
    end

    allow(agent).to receive(:chat).and_return(fake_chat)

    workflow = with_stubbed_class("SpecExecutionNamespaceWorkflow", workflow_class) do
      initial_state :idle
      state :done

      transition :finish, from: :idle, to: :done do
        execute :spec_execution_namespace_agent
      end
    end.new

    workflow.run!
    state = workflow.to_state
    restored = workflow.class.from_state(state)

    expect(state[:execution_namespace]).to be_a(String)
    expect(state[:execution_namespace]).not_to be_empty
    expect(restored.to_state[:execution_namespace]).to eq(state[:execution_namespace])
  end

  it "serializes budget_consumed from the live ledger after workflow execution" do
    agent_class = require_const("Smith::Agent")

    agent = with_stubbed_class("SpecBudgetStateAgent", agent_class) do
      register_as :spec_budget_state_agent
      model "gpt-5-mini"
    end

    fake_chat = Object.new
    fake_chat.define_singleton_method(:add_message) { |_message| nil }
    fake_chat.define_singleton_method(:complete) do
      Struct.new(:content, :input_tokens, :output_tokens).new("ok", 7, 5)
    end

    allow(agent).to receive(:chat).and_return(fake_chat)

    workflow = with_stubbed_class("SpecBudgetStateWorkflow", workflow_class) do
      initial_state :idle
      state :done
      budget total_tokens: 100

      transition :finish, from: :idle, to: :done do
        execute :spec_budget_state_agent
      end
    end.new

    workflow.run!
    state = workflow.to_state

    expect(state[:budget_consumed]).to eq(total_tokens: 12)
  end

  it "restores a live ledger with the same consumed and remaining budget" do
    agent_class = require_const("Smith::Agent")

    agent = with_stubbed_class("SpecRestoredBudgetAgent", agent_class) do
      register_as :spec_restored_budget_agent
      model "gpt-5-mini"
    end

    fake_chat = Object.new
    fake_chat.define_singleton_method(:add_message) { |_message| nil }
    fake_chat.define_singleton_method(:complete) do
      Struct.new(:content, :input_tokens, :output_tokens).new("ok", 7, 5)
    end

    allow(agent).to receive(:chat).and_return(fake_chat)

    workflow_class_with_budget = with_stubbed_class("SpecRestoredBudgetWorkflow", workflow_class) do
      initial_state :idle
      state :done
      budget total_tokens: 100

      transition :finish, from: :idle, to: :done do
        execute :spec_restored_budget_agent
      end
    end

    workflow = workflow_class_with_budget.new
    workflow.run!

    restored = workflow_class_with_budget.from_state(workflow.to_state)

    expect(restored.ledger).not_to be_nil
    expect(restored.ledger.consumed).to eq(total_tokens: 12)
    expect(restored.ledger.remaining(:total_tokens)).to eq(88)
  end

  it "continues reconciling budget after restore using the restored ledger state" do
    agent_class = require_const("Smith::Agent")

    agent = with_stubbed_class("SpecResumeBudgetAgent", agent_class) do
      register_as :spec_resume_budget_agent
      model "gpt-5-mini"
    end

    responses = [
      Struct.new(:content, :input_tokens, :output_tokens).new("step-one", 7, 5),
      Struct.new(:content, :input_tokens, :output_tokens).new("step-two", 7, 5)
    ]

    allow(agent).to receive(:chat) do
      response = responses.shift
      chat = Object.new
      chat.define_singleton_method(:add_message) { |_message| nil }
      chat.define_singleton_method(:complete) { response }
      chat
    end

    workflow_class_with_budget = with_stubbed_class("SpecResumeBudgetWorkflow", workflow_class) do
      initial_state :idle
      state :mid
      state :done
      budget total_tokens: 20

      transition :first, from: :idle, to: :mid do
        execute :spec_resume_budget_agent
      end

      transition :second, from: :mid, to: :done do
        execute :spec_resume_budget_agent
      end
    end

    workflow = workflow_class_with_budget.new
    workflow.advance!

    restored = workflow_class_with_budget.from_state(workflow.to_state)
    observed = Queue.new

    allow(restored.ledger).to receive(:reserve!).and_wrap_original do |original, key, amount|
      observed << [:reserve, key, amount]
      original.call(key, amount)
    end

    result = restored.run!

    expect(result.state).to eq(:done)
    expect(restored.ledger.consumed).to eq(total_tokens: 24)

    entries = []
    entries << observed.pop until observed.empty?
    expect(entries).to include([:reserve, :total_tokens, 8])
  end
end
