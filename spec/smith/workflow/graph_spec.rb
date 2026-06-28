# frozen_string_literal: true

RSpec.describe "Smith::Workflow graph inspection" do
  let(:workflow_class) { require_const("Smith::Workflow") }

  it "exposes a read-only workflow graph report without changing runtime execution" do
    workflow = with_stubbed_class("SpecGraphValidWorkflow", workflow_class) do
      initial_state :idle
      state :queued
      state :done
      state :failed

      transition :start, from: :idle, to: :queued do
        on_success :finish
        on_failure :fail
      end

      transition :finish, from: :queued, to: :done
    end

    report = workflow.validate_graph

    expect(report).to be_valid
    expect(report.status).to eq(:valid)
    expect(report.workflow_class).to eq("SpecGraphValidWorkflow")
    expect(report.initial_state).to eq(:idle)
    expect(report.transitions.map(&:name)).to include(:start, :finish, :fail)
    expect(report.transitions.find { |transition| transition.name == :start }.kind).to eq(:noop)
    expect(report.metrics).to include(
      states_count: 4,
      transitions_count: 3,
      reachable_transitions_count: 3
    )
    expect(workflow.new.run!.state).to eq(:done)
  end

  it "reports unresolved named transition targets before runtime" do
    workflow = with_stubbed_class("SpecGraphMissingTargetWorkflow", workflow_class) do
      initial_state :idle
      state :ready
      state :failed

      transition :start, from: :idle, to: :ready do
        on_success :missing_finish
        on_failure :missing_fail
      end
    end

    report = workflow.validate_graph

    expect(report).not_to be_valid
    expect(report.status).to eq(:invalid)
    expect(report.errors.map(&:code)).to include(:unresolved_success_transition, :unresolved_failure_transition)
    expect(report.suggestions).to include(
      "Declare transition :missing_finish or update transition :start.",
      "Declare transition :missing_fail or update transition :start."
    )
  end

  it "reports unresolved router targets and state mismatches" do
    workflow = with_stubbed_class("SpecGraphRouterWorkflow", workflow_class) do
      initial_state :idle
      state :triaged
      state :refund_done
      state :support_done

      transition :classify, from: :idle, to: :triaged do
        route :router_agent,
              routes: { refund: :handle_refund, support: :missing_support },
              confidence_threshold: 0.75,
              fallback: :handle_general
      end

      transition :handle_refund, from: :idle, to: :refund_done
      transition :handle_general, from: :triaged, to: :support_done
    end

    report = workflow.validate_graph

    expect(report.status).to eq(:invalid)
    expect(report.errors.map(&:code)).to include(:unresolved_router_target)
    expect(report.warnings.map(&:code)).to include(:target_from_state_mismatch)

    mismatch = report.warnings.find { |diagnostic| diagnostic.code == :target_from_state_mismatch }
    expect(mismatch.transition).to eq(:classify)
    expect(mismatch.target).to eq(:handle_refund)
    expect(mismatch.message).to include(":handle_refund starts from :idle instead of :triaged")
  end

  it "reports undefined states and unreachable transitions" do
    workflow = with_stubbed_class("SpecGraphUnreachableWorkflow", workflow_class) do
      initial_state :idle
      state :done

      transition :start, from: :idle, to: :missing_state
      transition :orphan, from: :orphaned, to: :done
    end

    report = workflow.validate_graph

    expect(report.status).to eq(:invalid)
    expect(report.errors.map(&:code)).to include(:undefined_to_state, :undefined_from_state)
    expect(report.warnings.map(&:code)).to include(:unreachable_transition)
    expect(report.to_h.dig(:metrics, :terminal_states)).to include(:done)
  end

  it "preserves declared names without coercing workflow topology" do
    workflow = with_stubbed_class("SpecGraphStringNamedWorkflow", workflow_class) do
      initial_state "idle"
      state "done"

      transition "start", from: "idle", to: "done"
    end

    report = workflow.validate_graph

    expect(report).to be_valid
    expect(report.initial_state).to eq("idle")
    expect(report.states).to eq(%w[idle done])
    expect(report.transitions.map(&:name)).to include("start")
  end
end
