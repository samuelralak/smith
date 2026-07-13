# frozen_string_literal: true

RSpec.describe "Smith::Workflow contract" do
  let(:workflow_class) { require_const("Smith::Workflow") }

  it "exposes the workflow DSL used throughout the architecture" do
    %i[
      initial_state
      state
      transition
      graph
      validate_graph
      budget
      max_transitions
      guardrails
      context_manager
      seed_messages
      persistence_key
    ].each do |dsl|
      expect(workflow_class).to respond_to(dsl), "expected Smith::Workflow to implement .#{dsl}"
    end
  end

  it "supports stepwise execution, full-run execution, serialization hooks, and durability helpers" do
    workflow = workflow_class.allocate

    expect(workflow).to respond_to(:advance!)
    expect(workflow).to respond_to(:run!)
    expect(workflow).to respond_to(:state)
    expect(workflow).to respond_to(:terminal?)
    expect(workflow).to respond_to(:pending_transition_name)
    expect(workflow).to respond_to(:done?)
    expect(workflow).to respond_to(:failed?)
    expect(workflow).to respond_to(:advance_persisted!)
    expect(workflow).to respond_to(:prepare_persisted_step!)
    expect(workflow).to respond_to(:confirm_prepared_step!)
    expect(workflow).to respond_to(:execute_prepared_step!)
    expect(workflow).to respond_to(:prepared_persisted_step)
    expect(workflow).to respond_to(:prepared_persisted_step?)
    expect(workflow).to respond_to(:complete_persisted_step!)
    expect(workflow).to respond_to(:persist!)
    expect(workflow).to respond_to(:clear_persisted!)
    expect(workflow).to respond_to(:run_persisted!)
    expect(workflow).to respond_to(:to_state)
    expect(workflow_class).to respond_to(:restore)
    expect(workflow_class).to respond_to(:restore_or_initialize)
    expect(workflow_class).to respond_to(:run_persisted!)
    expect(workflow_class).to respond_to(:from_state)
  end

  it "indexes pending transitions without changing declaration order" do
    parent = with_stubbed_class("SpecIndexedWorkflow", workflow_class) do
      initial_state :idle
      state :first_done
      state :second_done

      transition :first, from: :idle, to: :first_done
      transition :second, from: :idle, to: :second_done
    end
    child = Class.new(parent)

    expect(parent.transitions_from(:idle).map(&:name)).to eq(%i[first second])
    expect(parent.new.pending_transition_name).to eq(:first)

    child.transition :first, from: :first_done, to: :second_done

    expect(parent.transitions_from(:idle).map(&:name)).to eq(%i[first second])
    expect(child.transitions_from(:idle).map(&:name)).to eq([:second])
    expect(child.transitions_from(:first_done).map(&:name)).to eq([:first])

    child.transition :second, from: :first_done, to: :second_done

    expect(child.transitions_from(:first_done).map(&:name)).to eq(%i[first second])
  end

  it "supports the documented transition DSL shape" do
    klass = with_stubbed_class("SpecWorkflow", workflow_class) do
      initial_state :idle
      state :ready
      state :failed
      budget total_cost: 2.0, wall_clock: 600
      max_transitions 30

      transition :start, from: :idle, to: :ready do
        execute :spec_research_agent
        on_success :finish
        on_failure :fail
      end
    end

    expect(klass).to be < workflow_class
  end

  it "stores the documented transition metadata for execute, on_success, and on_failure" do
    klass = with_stubbed_class("SpecTransitionMetadataWorkflow", workflow_class) do
      initial_state :idle
      state :ready

      transition :start, from: :idle, to: :ready do
        execute :spec_research_agent, schema: :result_schema
        on_success :finish
        on_failure :fail
      end
    end

    transition = klass.instance_variable_get(:@transitions).fetch(:start)

    expect(transition.name).to eq(:start)
    expect(transition.from).to eq(:idle)
    expect(transition.to).to eq(:ready)
    expect(transition.agent_name).to eq(:spec_research_agent)
    expect(transition.agent_opts).to eq(schema: :result_schema)
    expect(transition.success_transition).to eq(:finish)
    expect(transition.failure_transition).to eq(:fail)
  end

  it "auto-generates a default fail transition when a failed state exists" do
    klass = with_stubbed_class("SpecAutoFailWorkflow", workflow_class) do
      initial_state :idle
      state :processing
      state :failed

      transition :start, from: :idle, to: :processing do
        execute :spec_research_agent
        on_failure :fail
      end
    end

    transitions = klass.instance_variable_get(:@transitions)

    expect(transitions).to include(:fail)

    fail_transition = transitions.fetch(:fail)
    expect(fail_transition.name).to eq(:fail)
    expect(fail_transition.to).to eq(:failed)
  end

  it "allows an explicit fail transition to override the auto-generated default" do
    klass = with_stubbed_class("SpecExplicitFailWorkflow", workflow_class) do
      initial_state :idle
      state :processing
      state :failed

      transition :fail, from: :processing, to: :failed do
        execute :failure_agent, mode: :cleanup
      end
    end

    fail_transition = klass.instance_variable_get(:@transitions).fetch(:fail)

    expect(fail_transition.from).to eq(:processing)
    expect(fail_transition.to).to eq(:failed)
    expect(fail_transition.agent_name).to eq(:failure_agent)
    expect(fail_transition.agent_opts).to eq(mode: :cleanup)
  end

  it "fails a step loudly when an execute transition references an unregistered agent symbol" do
    workflow = with_stubbed_class("SpecUnresolvedAgentWorkflow", workflow_class) do
      initial_state :idle
      state :done
      state :failed

      transition :start, from: :idle, to: :done do
        execute :missing_research_agent
        on_failure :fail
      end
    end.new

    step = workflow.advance!

    expect(workflow.state).to eq(:failed)
    expect(step[:error]).to be_a(require_const("Smith::WorkflowError"))
    expect(step[:error].message).to include("unresolved agent :missing_research_agent")
    expect(step[:error].message).to include("transition :start")
  end

  it "raises the original step error when no failure transition is declared" do
    workflow = with_stubbed_class("SpecUnhandledFailureWorkflow", workflow_class) do
      initial_state :idle
      state :done

      transition :start, from: :idle, to: :done do
        execute :missing_research_agent
      end
    end.new

    expect { workflow.run! }
      .to raise_error(require_const("Smith::WorkflowError"), /unresolved agent :missing_research_agent/)
  end

  it "executes actionable failure transitions instead of only jumping to their target state" do
    workflow = with_stubbed_class("SpecActionableFailureWorkflow", workflow_class) do
      initial_state :idle
      state :done
      state :failed

      transition :start, from: :idle, to: :done do
        execute :missing_research_agent
        on_failure :cleanup
      end

      transition :cleanup, from: :idle, to: :failed do
        compute { |step| step.write_context(:cleaned_up, true) }
      end
    end.new

    result = workflow.run!

    expect(result.state).to eq(:failed)
    expect(result.context[:cleaned_up]).to be true
    expect(result.steps.map { |step| step[:transition] }).to eq(%i[start cleanup])
  end

  it "rejects jump-only failure transitions whose origin state does not match the current state" do
    workflow = with_stubbed_class("SpecFailureOriginMismatchWorkflow", workflow_class) do
      initial_state :idle
      state :other
      state :done
      state :failed

      transition :start, from: :idle, to: :done do
        execute :missing_research_agent
        on_failure :fail
      end

      transition :fail, from: :other, to: :failed
    end.new

    expect { workflow.run! }
      .to raise_error(require_const("Smith::WorkflowError"), /cannot run from state :idle/)
  end

  it "rejects named transitions whose origin state does not match the current state" do
    workflow = with_stubbed_class("SpecNamedTransitionOriginWorkflow", workflow_class) do
      initial_state :idle
      state :middle
      state :other
      state :done

      transition :start, from: :idle, to: :middle do
        on_success :finish
      end

      transition :finish, from: :other, to: :done
    end.new

    expect { workflow.run! }
      .to raise_error(require_const("Smith::WorkflowError"), /cannot run from state :middle/)
  end
end
