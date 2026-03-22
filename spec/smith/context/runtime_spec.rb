# frozen_string_literal: true

RSpec.describe "Smith::Context runtime contract" do
  let(:context_class) { require_const("Smith::Context") }
  let(:workflow_class) { require_const("Smith::Workflow") }
  let(:agent_class) { require_const("Smith::Agent") }
  let(:guardrails_class) { require_const("Smith::Guardrails") }

  it "returns the declared session strategy configuration" do
    manager = with_stubbed_class("SpecMaskingContext", context_class) do
      session_strategy :observation_masking, window: 10
    end

    expect(manager.session_strategy).to eq(strategy: :observation_masking, window: 10)
  end

  it "returns the declared persisted workflow context keys in order" do
    manager = with_stubbed_class("SpecPersistContext", context_class) do
      persist :current_findings, :source_urls, :user_context
    end

    expect(manager.persist).to eq(%i[current_findings source_urls user_context])
  end

  it "stores an inject_state formatter that can be called with persisted state" do
    manager = with_stubbed_class("SpecInjectContext", context_class) do
      inject_state do |persisted|
        "summary: #{persisted[:current_findings]}"
      end
    end

    formatter = manager.inject_state

    expect(formatter).to respond_to(:call)
    expect(formatter.call(current_findings: "timeline stable")).to eq("summary: timeline stable")
  end

  it "copies persisted keys into subclasses without mutating the parent" do
    parent = with_stubbed_class("SpecParentContext", context_class) do
      persist :current_findings
    end

    child = with_stubbed_class("SpecChildContext", parent) do
      persist :source_urls
    end

    expect(parent.persist).to eq(%i[current_findings])
    expect(child.persist).to eq(%i[current_findings source_urls])
  end

  it "allows subclasses to override inject_state without mutating the parent" do
    parent = with_stubbed_class("SpecParentInjectContext", context_class) do
      inject_state { |_persisted| "parent" }
    end

    child = with_stubbed_class("SpecChildInjectContext", parent) do
      inject_state { |_persisted| "child" }
    end

    expect(parent.inject_state.call({})).to eq("parent")
    expect(child.inject_state.call({})).to eq("child")
  end

  it "uses a masked prepared input without mutating stored session messages" do
    manager = with_stubbed_class("SpecPreparedMaskingContext", context_class) do
      session_strategy :observation_masking, window: 1

      inject_state do |persisted|
        "summary: #{persisted[:current_findings]}"
      end
    end

    workflow = with_stubbed_class("SpecPreparedMaskingWorkflow", workflow_class) do
      context_manager manager
      initial_state :idle
      state :done

      transition :finish, from: :idle, to: :done do
        execute :spec_context_agent
      end
    end.new(context: { current_findings: "stable" })

    workflow.instance_variable_set(
      :@session_messages,
      [
        { role: :user, content: "older" },
        { role: :assistant, content: "middle" },
        { role: :user, content: "latest" }
      ]
    )

    workflow.run!

    expect(workflow.last_prepared_input).to eq(
      [
        { role: :system, content: "[smith:injected-state]\nsummary: stable" },
        { role: :user, content: "latest" }
      ]
    )

    expect(workflow.session_messages).to eq(
      [
        { role: :user, content: "older" },
        { role: :assistant, content: "middle" },
        { role: :user, content: "latest" },
        { role: :system, content: "[smith:injected-state]\nsummary: stable" }
      ]
    )
  end

  it "replaces prior injected state instead of duplicating it on repeated preparation" do
    manager = with_stubbed_class("SpecReplacingInjectionContext", context_class) do
      inject_state do |persisted|
        "summary: #{persisted[:current_findings]}"
      end
    end

    workflow = with_stubbed_class("SpecReplacingInjectionWorkflow", workflow_class) do
      context_manager manager
      initial_state :idle
      state :done

      transition :finish, from: :idle, to: :done do
        execute :spec_context_agent
      end
    end.new(context: { current_findings: "first" })

    workflow.run!

    workflow.instance_variable_set(:@state, :idle)
    workflow.instance_variable_set(:@next_transition_name, nil)
    workflow.instance_variable_set(:@context, { current_findings: "second" })

    workflow.run!

    injected_messages = workflow.session_messages.select do |message|
      message[:content].start_with?("[smith:injected-state]")
    end

    expect(injected_messages.length).to eq(1)
    expect(injected_messages.first[:content]).to eq("[smith:injected-state]\nsummary: second")
    expect(workflow.last_prepared_input).to eq(
      [{ role: :system, content: "[smith:injected-state]\nsummary: second" }]
    )
  end

  it "appends accepted workflow output to stored session messages" do
    agent = with_stubbed_class("SpecAcceptedSessionAgent", agent_class) do
      register_as :spec_accepted_session_agent
      model "gpt-5-mini"
    end

    fake_chat = Object.new
    fake_chat.define_singleton_method(:add_message) { |_message| nil }
    fake_chat.define_singleton_method(:complete) do
      Struct.new(:content).new({ "status" => "ok" })
    end

    allow(agent).to receive(:chat).and_return(fake_chat)

    manager = with_stubbed_class("SpecAcceptedSessionContext", context_class) do
      inject_state do |persisted|
        "summary: #{persisted[:current_findings]}"
      end
    end

    workflow = with_stubbed_class("SpecAcceptedSessionWorkflow", workflow_class) do
      context_manager manager
      initial_state :idle
      state :done

      transition :finish, from: :idle, to: :done do
        execute :spec_accepted_session_agent
      end
    end.new(context: { current_findings: "stable" })

    workflow.instance_variable_set(:@session_messages, [{ role: :user, content: "latest" }])

    result = workflow.run!

    expect(result.state).to eq(:done)
    expect(workflow.session_messages).to eq(
      [
        { role: :user, content: "latest" },
        { role: :system, content: "[smith:injected-state]\nsummary: stable" },
        { role: :assistant, content: { "status" => "ok" } }
      ]
    )
  end

  it "appends accepted falsy workflow output to stored session messages" do
    agent = with_stubbed_class("SpecFalsySessionAgent", agent_class) do
      register_as :spec_falsy_session_agent
      model "gpt-5-mini"
    end

    fake_chat = Object.new
    fake_chat.define_singleton_method(:add_message) { |_message| nil }
    fake_chat.define_singleton_method(:complete) do
      Struct.new(:content).new(false)
    end

    allow(agent).to receive(:chat).and_return(fake_chat)

    manager = with_stubbed_class("SpecFalsySessionContext", context_class) do
      inject_state { |_persisted| "summary: keep false" }
    end

    workflow = with_stubbed_class("SpecFalsySessionWorkflow", workflow_class) do
      context_manager manager
      initial_state :idle
      state :done

      transition :finish, from: :idle, to: :done do
        execute :spec_falsy_session_agent
      end
    end.new

    workflow.instance_variable_set(:@session_messages, [])

    result = workflow.run!

    expect(result.state).to eq(:done)
    expect(workflow.session_messages.last).to eq(role: :assistant, content: false)
  end

  it "does not append rejected output to session messages when an output guardrail fails" do
    agent = with_stubbed_class("SpecRejectedSessionAgent", agent_class) do
      register_as :spec_rejected_session_agent
      model "gpt-5-mini"
    end

    fake_chat = Object.new
    fake_chat.define_singleton_method(:add_message) { |_message| nil }
    fake_chat.define_singleton_method(:complete) do
      Struct.new(:content).new("rejected output")
    end

    allow(agent).to receive(:chat).and_return(fake_chat)

    manager = with_stubbed_class("SpecRejectedSessionContext", context_class) do
      inject_state { |_persisted| "summary: still persisted" }
    end

    workflow_guardrails = with_stubbed_class("SpecRejectedSessionGuardrails", guardrails_class) do
      define_method(:reject_output) { |_payload| raise "bad output" }
      output :reject_output
    end

    workflow = with_stubbed_class("SpecRejectedSessionWorkflow", workflow_class) do
      context_manager manager
      guardrails workflow_guardrails
      initial_state :idle
      state :done
      state :failed

      transition :finish, from: :idle, to: :done do
        execute :spec_rejected_session_agent
        on_failure :fail
      end
    end.new

    workflow.instance_variable_set(:@session_messages, [{ role: :user, content: "latest" }])

    result = workflow.run!

    expect(result.state).to eq(:failed)
    expect(workflow.session_messages).to eq(
      [
        { role: :user, content: "latest" },
        { role: :system, content: "[smith:injected-state]\nsummary: still persisted" }
      ]
    )
  end
end
