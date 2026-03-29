# frozen_string_literal: true

RSpec.describe "Smith::Workflow::Router runtime behavior" do
  let(:agent_class) { require_const("Smith::Agent") }
  let(:guardrails_class) { require_const("Smith::Guardrails") }
  let(:guardrail_failed) { require_const("Smith::GuardrailFailed") }
  let(:workflow_class) { require_const("Smith::Workflow") }
  let(:workflow_error) { require_const("Smith::WorkflowError") }

  def stub_classifier(klass, result)
    allow(klass).to receive(:chat) do
      chat = Object.new
      chat.define_singleton_method(:add_message) { |_msg| nil }
      chat.define_singleton_method(:complete) do
        Struct.new(:content, :input_tokens, :output_tokens).new(result, 5, 3)
      end
      chat
    end
  end

  it "selects the mapped specialist transition when confidence meets the threshold" do
    classifier = with_stubbed_class("SpecRouterHighConfClassifier", agent_class) do
      register_as :spec_router_high_conf_classifier
      model "gpt-5-mini"
    end

    stub_classifier(classifier, { route: :refund, confidence: 0.9 })

    workflow = with_stubbed_class("SpecRouterHighConfWorkflow", workflow_class) do
      initial_state :idle
      state :triaged
      state :handling_refund
      state :handling_general
      state :failed

      transition :classify, from: :idle, to: :triaged do
        route :spec_router_high_conf_classifier,
              routes: { refund: :handle_refund, support: :handle_support },
              confidence_threshold: 0.75,
              fallback: :handle_general
        on_failure :fail
      end

      transition :handle_refund, from: :triaged, to: :handling_refund
      transition :handle_support, from: :triaged, to: :handling_refund
      transition :handle_general, from: :triaged, to: :handling_general
    end.new

    step = workflow.advance!

    expect(step[:transition]).to eq(:classify)
    expect(workflow.state).to eq(:triaged)

    next_step = workflow.advance!

    expect(next_step[:transition]).to eq(:handle_refund)
    expect(workflow.state).to eq(:handling_refund)
  end

  it "selects the fallback transition when confidence is below the threshold" do
    classifier = with_stubbed_class("SpecRouterLowConfClassifier", agent_class) do
      register_as :spec_router_low_conf_classifier
      model "gpt-5-mini"
    end

    stub_classifier(classifier, { route: :refund, confidence: 0.5 })

    workflow = with_stubbed_class("SpecRouterLowConfWorkflow", workflow_class) do
      initial_state :idle
      state :triaged
      state :handling_refund
      state :handling_general
      state :failed

      transition :classify, from: :idle, to: :triaged do
        route :spec_router_low_conf_classifier,
              routes: { refund: :handle_refund },
              confidence_threshold: 0.75,
              fallback: :handle_general
        on_failure :fail
      end

      transition :handle_refund, from: :triaged, to: :handling_refund
      transition :handle_general, from: :triaged, to: :handling_general
    end.new

    workflow.advance!

    expect(workflow.state).to eq(:triaged)

    next_step = workflow.advance!

    expect(next_step[:transition]).to eq(:handle_general)
    expect(workflow.state).to eq(:handling_general)
  end

  it "fails the step normally when the route key is not in declared routes" do
    classifier = with_stubbed_class("SpecRouterUnknownRouteClassifier", agent_class) do
      register_as :spec_router_unknown_route_classifier
      model "gpt-5-mini"
    end

    stub_classifier(classifier, { route: :billing, confidence: 0.9 })

    workflow = with_stubbed_class("SpecRouterUnknownRouteWorkflow", workflow_class) do
      initial_state :idle
      state :triaged
      state :failed

      transition :classify, from: :idle, to: :triaged do
        route :spec_router_unknown_route_classifier,
              routes: { refund: :handle_refund },
              confidence_threshold: 0.75,
              fallback: :handle_general
        on_failure :fail
      end
    end.new

    step = workflow.advance!

    expect(workflow.state).to eq(:failed)
    expect(step[:error]).to be_a(workflow_error)
    expect(step[:error].message).to include("billing")
  end

  it "fails the step loudly when the router agent symbol is not registered" do
    workflow = with_stubbed_class("SpecRouterMissingRegisteredAgentWorkflow", workflow_class) do
      initial_state :idle
      state :triaged
      state :failed

      transition :classify, from: :idle, to: :triaged do
        route :missing_router_agent,
              routes: { refund: :handle_refund },
              confidence_threshold: 0.75,
              fallback: :handle_general
        on_failure :fail
      end
    end.new

    step = workflow.advance!

    expect(workflow.state).to eq(:failed)
    expect(step[:error]).to be_a(workflow_error)
    expect(step[:error].message).to include("unresolved agent :missing_router_agent")
    expect(step[:error].message).to include("transition :classify")
  end

  it "fails the step normally when the mapped transition is not declared on the workflow" do
    classifier = with_stubbed_class("SpecRouterUndeclaredMappedTransitionClassifier", agent_class) do
      register_as :spec_router_undeclared_mapped_transition_classifier
      model "gpt-5-mini"
    end

    stub_classifier(classifier, { route: :refund, confidence: 0.9 })

    workflow = with_stubbed_class("SpecRouterUndeclaredMappedTransitionWorkflow", workflow_class) do
      initial_state :idle
      state :triaged
      state :failed

      transition :classify, from: :idle, to: :triaged do
        route :spec_router_undeclared_mapped_transition_classifier,
              routes: { refund: :handle_refund },
              confidence_threshold: 0.75,
              fallback: :handle_general
        on_failure :fail
      end

      transition :handle_general, from: :triaged, to: :triaged
    end.new

    step = workflow.advance!

    expect(workflow.state).to eq(:failed)
    expect(step[:error]).to be_a(workflow_error)
    expect(step[:error].message).to include("not declared on the workflow")
  end

  it "fails the step normally when :route key is missing from classifier output" do
    classifier = with_stubbed_class("SpecRouterMissingRouteClassifier", agent_class) do
      register_as :spec_router_missing_route_classifier
      model "gpt-5-mini"
    end

    stub_classifier(classifier, { confidence: 0.9 })

    workflow = with_stubbed_class("SpecRouterMissingRouteWorkflow", workflow_class) do
      initial_state :idle
      state :triaged
      state :failed

      transition :classify, from: :idle, to: :triaged do
        route :spec_router_missing_route_classifier,
              routes: { refund: :handle_refund },
              confidence_threshold: 0.75,
              fallback: :handle_general
        on_failure :fail
      end
    end.new

    step = workflow.advance!

    expect(workflow.state).to eq(:failed)
    expect(step[:error]).to be_a(workflow_error)
    expect(step[:error].message).to include("route")
  end

  it "fails the step normally when :confidence key is missing from classifier output" do
    classifier = with_stubbed_class("SpecRouterMissingConfClassifier", agent_class) do
      register_as :spec_router_missing_conf_classifier
      model "gpt-5-mini"
    end

    stub_classifier(classifier, { route: :refund })

    workflow = with_stubbed_class("SpecRouterMissingConfWorkflow", workflow_class) do
      initial_state :idle
      state :triaged
      state :failed

      transition :classify, from: :idle, to: :triaged do
        route :spec_router_missing_conf_classifier,
              routes: { refund: :handle_refund },
              confidence_threshold: 0.75,
              fallback: :handle_general
        on_failure :fail
      end
    end.new

    step = workflow.advance!

    expect(workflow.state).to eq(:failed)
    expect(step[:error]).to be_a(workflow_error)
    expect(step[:error].message).to include("confidence")
  end

  it "fails the step normally when confidence is outside 0.0..1.0" do
    classifier = with_stubbed_class("SpecRouterBadConfClassifier", agent_class) do
      register_as :spec_router_bad_conf_classifier
      model "gpt-5-mini"
    end

    stub_classifier(classifier, { route: :refund, confidence: 1.5 })

    workflow = with_stubbed_class("SpecRouterBadConfWorkflow", workflow_class) do
      initial_state :idle
      state :triaged
      state :failed

      transition :classify, from: :idle, to: :triaged do
        route :spec_router_bad_conf_classifier,
              routes: { refund: :handle_refund },
              confidence_threshold: 0.75,
              fallback: :handle_general
        on_failure :fail
      end
    end.new

    step = workflow.advance!

    expect(workflow.state).to eq(:failed)
    expect(step[:error]).to be_a(workflow_error)
    expect(step[:error].message).to include("confidence")
  end

  it "fails the step normally when classifier output is not a Hash" do
    classifier = with_stubbed_class("SpecRouterNonHashClassifier", agent_class) do
      register_as :spec_router_non_hash_classifier
      model "gpt-5-mini"
    end

    stub_classifier(classifier, "not a hash")

    workflow = with_stubbed_class("SpecRouterNonHashWorkflow", workflow_class) do
      initial_state :idle
      state :triaged
      state :failed

      transition :classify, from: :idle, to: :triaged do
        route :spec_router_non_hash_classifier,
              routes: { refund: :handle_refund },
              confidence_threshold: 0.75,
              fallback: :handle_general
        on_failure :fail
      end
    end.new

    step = workflow.advance!

    expect(workflow.state).to eq(:failed)
    expect(step[:error]).to be_a(workflow_error)
    expect(step[:error].message).to include("Hash")
  end

  it "routes through on_failure when the classifier agent itself fails" do
    classifier = with_stubbed_class("SpecRouterAgentFailClassifier", agent_class) do
      register_as :spec_router_agent_fail_classifier
      model "gpt-5-mini"
    end

    allow(classifier).to receive(:chat) do
      chat = Object.new
      chat.define_singleton_method(:add_message) { |_msg| nil }
      chat.define_singleton_method(:complete) { raise StandardError, "provider down" }
      chat
    end

    workflow = with_stubbed_class("SpecRouterAgentFailWorkflow", workflow_class) do
      initial_state :idle
      state :triaged
      state :failed

      transition :classify, from: :idle, to: :triaged do
        route :spec_router_agent_fail_classifier,
              routes: { refund: :handle_refund },
              confidence_threshold: 0.75,
              fallback: :handle_general
        on_failure :fail
      end
    end.new

    step = workflow.advance!

    expect(workflow.state).to eq(:failed)
    expect(step[:error]).to be_a(Smith::AgentError)
  end

  it "fails the step normally when the fallback transition is not declared on the workflow" do
    classifier = with_stubbed_class("SpecRouterUndeclaredFallbackClassifier", agent_class) do
      register_as :spec_router_undeclared_fallback_classifier
      model "gpt-5-mini"
    end

    stub_classifier(classifier, { route: :refund, confidence: 0.5 })

    workflow = with_stubbed_class("SpecRouterUndeclaredFallbackWorkflow", workflow_class) do
      initial_state :idle
      state :triaged
      state :failed

      transition :classify, from: :idle, to: :triaged do
        route :spec_router_undeclared_fallback_classifier,
              routes: { refund: :handle_refund },
              confidence_threshold: 0.75,
              fallback: :handle_general
        on_failure :fail
      end

      transition :handle_refund, from: :triaged, to: :triaged
    end.new

    step = workflow.advance!

    expect(workflow.state).to eq(:failed)
    expect(step[:error]).to be_a(workflow_error)
    expect(step[:error].message).to include("not declared on the workflow")
  end

  it "keeps router classifier output inside output guardrail validation before routing is finalized" do
    observed = []

    classifier = with_stubbed_class("SpecRouterOutputGuardrailClassifier", agent_class) do
      register_as :spec_router_output_guardrail_classifier
      model "gpt-5-mini"
    end

    stub_classifier(classifier, { route: :refund, confidence: 0.9 })

    workflow_guardrails = with_stubbed_class("SpecRouterOutputGuardrails", guardrails_class) do
      define_method(:reject_router_output) do |payload|
        observed << payload
        raise "bad router output"
      end

      output :reject_router_output
    end

    workflow = with_stubbed_class("SpecRouterOutputGuardrailWorkflow", workflow_class) do
      initial_state :idle
      state :triaged
      state :handling_refund
      state :failed
      guardrails workflow_guardrails

      transition :classify, from: :idle, to: :triaged do
        route :spec_router_output_guardrail_classifier,
              routes: { refund: :handle_refund },
              confidence_threshold: 0.75,
              fallback: :handle_general
        on_failure :fail
      end

      transition :handle_refund, from: :triaged, to: :handling_refund
      transition :handle_general, from: :triaged, to: :handling_refund
    end.new

    step = workflow.advance!

    expect(workflow.state).to eq(:failed)
    expect(step[:error]).to be_a(guardrail_failed)
    expect(observed).to eq([{ route: :refund, confidence: 0.9 }])
  end

  it "preserves transitions as the control-flow authority across a full routed workflow" do
    classifier = with_stubbed_class("SpecRouterFullFlowClassifier", agent_class) do
      register_as :spec_router_full_flow_classifier
      model "gpt-5-mini"
    end

    stub_classifier(classifier, { route: :support, confidence: 0.85 })

    workflow = with_stubbed_class("SpecRouterFullFlowWorkflow", workflow_class) do
      initial_state :idle
      state :triaged
      state :handled
      state :failed

      transition :classify, from: :idle, to: :triaged do
        route :spec_router_full_flow_classifier,
              routes: { refund: :handle_refund, support: :handle_support },
              confidence_threshold: 0.75,
              fallback: :handle_general
        on_failure :fail
      end

      transition :handle_refund, from: :triaged, to: :handled
      transition :handle_support, from: :triaged, to: :handled
      transition :handle_general, from: :triaged, to: :handled
    end.new

    result = workflow.run!

    expect(result.state).to eq(:handled)
    expect(result.steps.length).to eq(2)
    expect(result.steps[0][:transition]).to eq(:classify)
    expect(result.steps[1][:transition]).to eq(:handle_support)
  end
end
