# frozen_string_literal: true

require "json"

RSpec.describe "Smith::Workflow state serialization shape" do
  let(:workflow_class) { require_const("Smith::Workflow") }

  it "serializes to the documented state hash shape" do
    workflow = with_stubbed_class("SpecStateWorkflow", workflow_class) do
      persistence_key { |ctx| "workflow:#{ctx[:branch_count]}" }
      initial_state :idle
    end.new(context: { branch_count: 6, metadata: { topic: "history" } })

    workflow.persist!("workflow:6", adapter: Class.new {
      def store(_key, _payload); end
    }.new)

    state = workflow.to_state

    expect(state.keys).to eq(%i[class state persistence_key context budget_consumed step_count execution_namespace created_at updated_at next_transition_name session_messages total_cost total_tokens])
    expect(state[:class]).to eq("SpecStateWorkflow")
    expect(state[:state]).to eq(:idle)
    expect(state[:persistence_key]).to eq("workflow:6")
    expect(state[:context]).to eq(branch_count: 6, metadata: { topic: "history" })
    expect(state[:budget_consumed]).to be_a(Hash)
    expect(state[:step_count]).to be_a(Integer)
    expect(state[:created_at]).to be_a(String)
    expect(state[:updated_at]).to be_a(String)
    expect(state[:total_cost]).to eq(0.0)
    expect(state[:total_tokens]).to eq(0)
  end

  it "round-trips through from_state without serializing agent instances" do
    workflow = with_stubbed_class("SpecRoundTripWorkflow", workflow_class) do
      persistence_key { |ctx| "workflow:#{ctx[:branch_count]}" }
      initial_state :idle
    end.new(context: { branch_count: 3 })

    workflow.persist!("workflow:3", adapter: Class.new {
      def store(_key, _payload); end
    }.new)

    restored = workflow.class.from_state(workflow.to_state)

    expect(restored.to_state).to eq(workflow.to_state)
    expect(JSON.generate(restored.to_state)).to be_a(String)
  end

  it "restores the documented state semantics after a JSON host round-trip" do
    workflow = with_stubbed_class("SpecJsonRoundTripWorkflow", workflow_class) do
      initial_state :idle
      state :done

      transition :finish, from: :idle, to: :done
    end.new(context: { branch_count: 3 })

    workflow.instance_variable_set(:@next_transition_name, :finish)
    workflow.instance_variable_set(:@session_messages, [{ role: :user, content: { "topic" => "history" } }])

    parsed = JSON.parse(JSON.generate(workflow.to_state))
    restored = workflow.class.from_state(parsed)
    restored_state = restored.to_state
    result = restored.run!

    expect(restored_state[:state]).to eq(:idle)
    expect(restored_state[:next_transition_name]).to eq(:finish)
    expect(restored_state[:context]).to eq(branch_count: 3)
    expect(restored_state[:session_messages]).to eq(
      [{ role: "user", content: { "topic" => "history" } }]
    )
    expect(result.state).to eq(:done)
    expect(result.steps.map { |step| step[:transition] }).to eq([:finish])
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

  it "rebuilds the live ledger after a JSON host round-trip" do
    agent_class = require_const("Smith::Agent")

    agent = with_stubbed_class("SpecJsonBudgetAgent", agent_class) do
      register_as :spec_json_budget_agent
      model "gpt-5-mini"
    end

    fake_chat = Object.new
    fake_chat.define_singleton_method(:add_message) { |_message| nil }
    fake_chat.define_singleton_method(:complete) do
      Struct.new(:content, :input_tokens, :output_tokens).new("ok", 7, 5)
    end

    allow(agent).to receive(:chat).and_return(fake_chat)

    workflow_class_with_budget = with_stubbed_class("SpecJsonBudgetWorkflow", workflow_class) do
      initial_state :idle
      state :done
      budget total_tokens: 100

      transition :finish, from: :idle, to: :done do
        execute :spec_json_budget_agent
      end
    end

    workflow = workflow_class_with_budget.new
    workflow.run!

    parsed = JSON.parse(JSON.generate(workflow.to_state))
    restored = workflow_class_with_budget.from_state(parsed)

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

  it "preserves the selected next transition across serialization and resume" do
    agent_class = require_const("Smith::Agent")

    agent = with_stubbed_class("SpecPersistedNextTransitionAgent", agent_class) do
      register_as :spec_persisted_next_transition_agent
      model "gpt-5-mini"
    end

    fake_chat = Object.new
    fake_chat.define_singleton_method(:add_message) { |_message| nil }
    fake_chat.define_singleton_method(:complete) do
      Struct.new(:content).new("ok")
    end

    allow(agent).to receive(:chat).and_return(fake_chat)

    workflow_class_with_branch = with_stubbed_class("SpecPersistedNextTransitionWorkflow", workflow_class) do
      initial_state :idle
      state :branching
      state :chosen_done
      state :alternate_done

      transition :start, from: :idle, to: :branching do
        execute :spec_persisted_next_transition_agent
        on_success :chosen
      end

      transition :alternate, from: :branching, to: :alternate_done
      transition :chosen, from: :branching, to: :chosen_done
    end

    workflow = workflow_class_with_branch.new
    workflow.advance!

    state = workflow.to_state
    restored = workflow_class_with_branch.from_state(state)
    result = restored.run!

    expect(state[:next_transition_name]).to eq(:chosen)
    expect(result.state).to eq(:chosen_done)
    expect(result.steps.map { |step| step[:transition] }).to eq([:chosen])
  end

  it "preserves the selected next transition across a JSON host round-trip and resume" do
    agent_class = require_const("Smith::Agent")

    agent = with_stubbed_class("SpecJsonPersistedNextTransitionAgent", agent_class) do
      register_as :spec_json_persisted_next_transition_agent
      model "gpt-5-mini"
    end

    fake_chat = Object.new
    fake_chat.define_singleton_method(:add_message) { |_message| nil }
    fake_chat.define_singleton_method(:complete) do
      Struct.new(:content).new("ok")
    end

    allow(agent).to receive(:chat).and_return(fake_chat)

    workflow_class_with_branch = with_stubbed_class("SpecJsonPersistedNextTransitionWorkflow", workflow_class) do
      initial_state :idle
      state :branching
      state :chosen_done
      state :alternate_done

      transition :start, from: :idle, to: :branching do
        execute :spec_json_persisted_next_transition_agent
        on_success :chosen
      end

      transition :alternate, from: :branching, to: :alternate_done
      transition :chosen, from: :branching, to: :chosen_done
    end

    workflow = workflow_class_with_branch.new
    workflow.advance!

    parsed = JSON.parse(JSON.generate(workflow.to_state))
    restored = workflow_class_with_branch.from_state(parsed)
    restored_state = restored.to_state
    result = restored.run!

    expect(restored_state[:next_transition_name]).to eq(:chosen)
    expect(result.state).to eq(:chosen_done)
    expect(result.steps.map { |step| step[:transition] }).to eq([:chosen])
  end
end
