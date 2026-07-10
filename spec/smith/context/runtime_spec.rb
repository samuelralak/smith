# frozen_string_literal: true

RSpec.describe "Smith::Context runtime contract" do
  let(:context_class) { require_const("Smith::Context") }
  let(:workflow_class) { require_const("Smith::Workflow") }
  let(:agent_class) { require_const("Smith::Agent") }
  let(:guardrails_class) { require_const("Smith::Guardrails") }
  let!(:context_agent) do
    with_stubbed_class("SpecContextAgent", agent_class) do
      register_as :spec_context_agent
    end
  end

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

  it "merges injected state into the existing agent instruction system message before provider call" do
    manager = with_stubbed_class("SpecMergedInstructionContext", context_class) do
      session_strategy :observation_masking, window: 1

      inject_state do |persisted|
        "summary: #{persisted[:current_findings]}"
      end
    end

    agent = with_stubbed_class("SpecMergedInstructionAgent", agent_class) do
      register_as :spec_merged_instruction_agent
      model "gpt-5-mini"

      instructions do |_context|
        "agent instructions"
      end
    end

    message_class = Struct.new(:role, :content)
    chat_messages = [message_class.new(:system, "agent instructions")]

    fake_chat = Object.new
    fake_chat.define_singleton_method(:messages) { chat_messages }
    fake_chat.define_singleton_method(:with_instructions) do |instructions|
      system_messages, other_messages = chat_messages.partition { |msg| msg.role == :system }

      if system_messages.empty?
        chat_messages.replace([message_class.new(:system, instructions)] + other_messages)
      else
        system_messages.first.content = instructions
        chat_messages.replace([system_messages.first] + other_messages)
      end

      self
    end
    fake_chat.define_singleton_method(:add_message) do |message|
      chat_messages << message_class.new(message[:role], message[:content])
    end
    fake_chat.define_singleton_method(:complete) do
      Struct.new(:content).new("done")
    end

    allow(agent).to receive(:chat).and_return(fake_chat)

    workflow = with_stubbed_class("SpecMergedInstructionWorkflow", workflow_class) do
      context_manager manager
      initial_state :idle
      state :done

      transition :finish, from: :idle, to: :done do
        execute :spec_merged_instruction_agent
      end
    end.new(context: { current_findings: "stable" })

    workflow.instance_variable_set(:@session_messages, [{ role: :user, content: "latest" }])

    result = workflow.run!

    expect(result.state).to eq(:done)
    expect(chat_messages.map { |msg| [msg.role, msg.content] }).to eq(
      [
        [:system, "agent instructions\n\n[smith:injected-state]\nsummary: stable"],
        [:user, "latest"]
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

  it "adds a provider-safe workflow continuation when prepared input ends with an assistant turn" do
    first_agent = with_stubbed_class("SpecContinuationFirstAgent", agent_class) do
      register_as :spec_continuation_first_agent
      model "claude-sonnet-4-6"
    end
    second_agent = with_stubbed_class("SpecContinuationSecondAgent", agent_class) do
      register_as :spec_continuation_second_agent
      model "claude-sonnet-4-6"
    end

    first_messages = []
    second_messages = []
    first_chat = fake_chat(first_messages, "first output")
    second_chat = fake_chat(second_messages, "final output")

    allow(first_agent).to receive(:chat).and_return(first_chat)
    allow(second_agent).to receive(:chat).and_return(second_chat)

    workflow = with_stubbed_class("SpecContinuationWorkflow", workflow_class) do
      seed_messages { [{ role: :user, content: "initial request" }] }
      initial_state :idle
      state :reviewed
      state :done

      transition :first, from: :idle, to: :reviewed do
        execute :spec_continuation_first_agent
        on_success :second
      end

      transition :second, from: :reviewed, to: :done do
        execute :spec_continuation_second_agent
      end
    end.new

    result = workflow.run!

    expect(result.state).to eq(:done)
    expect(first_messages).to eq([{ role: :user, content: "initial request" }])
    expect(second_messages).to eq(
      [
        { role: :user, content: "initial request" },
        { role: :assistant, content: "first output" },
        {
          role: :user,
          content: "Use the preceding assistant result as input and perform your assigned workflow step."
        }
      ]
    )
    expect(workflow.session_messages).to eq(
      [
        { role: :user, content: "initial request" },
        { role: :assistant, content: "first output" },
        { role: :assistant, content: "final output" }
      ]
    )
  end

  it "recognizes restored string roles without mutating provider input" do
    workflow = workflow_class.allocate
    prepared_input = [
      { "role" => "user", "content" => "initial request" },
      { "role" => "assistant", "content" => "stage output" },
      { "role" => "system", "content" => "runtime state" }
    ].freeze
    workflow.instance_variable_set(:@last_output, { "status" => "accepted" })
    prepared_input[1]["content"] = { "status" => "accepted" }

    provider_input = workflow.send(:provider_safe_prepared_input, prepared_input)

    expect(provider_input).to eq(
      [
        *prepared_input,
        {
          role: :user,
          content: "Use the preceding assistant result as input and perform your assigned workflow step."
        }
      ]
    )
    expect(prepared_input.length).to eq(3)
    expect(provider_input).not_to equal(prepared_input)
  end

  it "does not add a continuation when the prepared input ends with a user turn" do
    workflow = workflow_class.allocate
    prepared_input = [
      { role: :assistant, content: "earlier output" },
      { role: :user, content: "active request" }
    ].freeze

    provider_input = workflow.send(:provider_safe_prepared_input, prepared_input)

    expect(provider_input).to eq(prepared_input)
    expect(prepared_input.length).to eq(2)
  end

  it "preserves an explicit assistant seed that is not a prior workflow output" do
    workflow = workflow_class.allocate
    prepared_input = [{ role: :assistant, content: "The answer is (" }].freeze

    provider_input = workflow.send(:provider_safe_prepared_input, prepared_input)

    expect(provider_input).to eq(prepared_input)
  end

  it "does not add a continuation to empty or system-only prepared input" do
    workflow = workflow_class.allocate
    workflow.instance_variable_set(:@last_output, "prior output")

    expect(workflow.send(:provider_safe_prepared_input, [])).to eq([])
    expect(
      workflow.send(:provider_safe_prepared_input, [{ role: :system, content: "runtime state" }])
    ).to eq([{ role: :system, content: "runtime state" }])
  end

  it "derives each provider continuation independently from shared prepared input" do
    workflow = workflow_class.allocate
    prepared_input = [{ role: :assistant, content: "shared branch input" }].freeze
    workflow.instance_variable_set(:@last_output, "shared branch input")

    provider_inputs = Array.new(3) do
      workflow.send(:provider_safe_prepared_input, prepared_input)
    end

    expect(provider_inputs.map(&:length)).to eq([2, 2, 2])
    expect(provider_inputs.map(&:object_id).uniq.length).to eq(3)
    expect(prepared_input.length).to eq(1)
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

  def fake_chat(messages, content)
    Object.new.tap do |chat|
      chat.define_singleton_method(:add_message) do |message|
        messages << message
        self
      end
      chat.define_singleton_method(:complete) do
        Struct.new(:content).new(content)
      end
    end
  end
end
