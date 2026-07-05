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

  it "reports deterministic route targets in snapshots, reachability, and diagnostics" do
    workflow = with_stubbed_class("SpecGraphDeterministicRoutesWorkflow", workflow_class) do
      initial_state :idle
      state :checked
      state :done

      transition :check, from: :idle, to: :checked do
        compute(routes: %i[finish missing_repair]) { |step| step.route_to(:finish) }
      end

      transition :finish, from: :checked, to: :done do
        run { |step| step.read_context(:noop) }
      end
    end

    report = workflow.validate_graph

    expect(report.status).to eq(:invalid)
    expect(report.errors.map(&:code)).to include(:unresolved_deterministic_route)
    expect(report.transitions.find { |transition| transition.name == :check }.deterministic_routes)
      .to eq(%i[finish missing_repair])
    expect(report.metrics.fetch(:reachable_transitions_count)).to eq(2)
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

  it "reports runtime readiness without executing agents" do
    agent_class = require_const("Smith::Agent")

    with_stubbed_class("SpecGraphReadyAgent", agent_class) do
      register_as :spec_graph_ready_agent
      model "gpt-4.1-nano"
    end

    workflow = with_stubbed_class("SpecGraphRuntimeReadyWorkflow", workflow_class) do
      initial_state :idle
      state :done

      transition :start, from: :idle, to: :done do
        execute :spec_graph_ready_agent
      end
    end

    report = workflow.runtime_readiness

    expect(report).to be_ready
    expect(report.status).to eq(:ready)
    expect(report.topology_status).to eq(:valid)
    expect(report.runtime_diagnostics).to be_empty
    expect(report.metrics).to include(
      agent_bindings_count: 1,
      unresolved_agent_bindings_count: 0,
      modelless_agent_bindings_count: 0
    )
  end

  it "separates topology validity from runtime readiness diagnostics" do
    workflow = with_stubbed_class("SpecGraphRuntimeNotReadyWorkflow", workflow_class) do
      initial_state :idle
      state :done

      transition :start, from: :idle, to: :done do
        execute :missing_runtime_agent
      end
    end

    report = workflow.runtime_readiness

    expect(report).not_to be_ready
    expect(report.status).to eq(:not_ready)
    expect(report.topology_status).to eq(:valid)
    expect(report.errors.map(&:code)).to include(:unresolved_agent_binding)
    expect(report.runtime_diagnostics.map(&:code)).to eq([:unresolved_agent_binding])
    expect(report.to_h).to include(:graph, :topology_diagnostics, :runtime_diagnostics)
  end

  it "warns for registered agents that have no model configured" do
    agent_class = require_const("Smith::Agent")

    with_stubbed_class("SpecGraphNoModelAgent", agent_class) do
      register_as :spec_graph_no_model_agent
    end

    workflow = with_stubbed_class("SpecGraphNoModelWorkflow", workflow_class) do
      initial_state :idle
      state :done

      transition :start, from: :idle, to: :done do
        execute :spec_graph_no_model_agent
      end
    end

    report = workflow.runtime_readiness

    expect(report).to be_ready
    expect(report.status).to eq(:warning)
    expect(report.warnings.map(&:code)).to include(:agent_without_model)
    expect(report.metrics.fetch(:modelless_agent_bindings_count)).to eq(1)
  end

  it "does not resolve lazy registry bindings while reporting them" do
    registry = require_const("Smith::Agent::Registry")
    calls = 0

    registry.register(:spec_graph_lazy_agent) do
      calls += 1
      require_const("Smith::Agent")
    end

    workflow = with_stubbed_class("SpecGraphLazyAgentWorkflow", workflow_class) do
      initial_state :idle
      state :done

      transition :start, from: :idle, to: :done do
        execute :spec_graph_lazy_agent
      end
    end

    report = workflow.runtime_readiness

    expect(report.status).to eq(:warning)
    expect(report.warnings.map(&:code)).to include(:uninspectable_agent_binding)
    expect(report.metrics.fetch(:uninspectable_agent_bindings_count)).to eq(1)
    expect(calls).to eq(0)
  end

  it "reports invalid non-agent registry bindings instead of crashing" do
    registry = require_const("Smith::Agent::Registry")
    registry.register(:spec_graph_plain_value_agent, "plain")

    workflow = with_stubbed_class("SpecGraphInvalidAgentBindingWorkflow", workflow_class) do
      initial_state :idle
      state :done

      transition :start, from: :idle, to: :done do
        execute :spec_graph_plain_value_agent
      end
    end

    report = workflow.runtime_readiness

    expect(report.status).to eq(:not_ready)
    expect(report.errors.map(&:code)).to include(:invalid_agent_binding)
    expect(report.metrics.fetch(:invalid_agent_bindings_count)).to eq(1)
  end

  it "reports unresolved bindings across route, optimize, orchestrate, and fan-out transitions" do
    schema = Class.new { def self.required_keys = [] }

    workflow = with_stubbed_class("SpecGraphRuntimeSpecializedMissingWorkflow", workflow_class) do
      initial_state :idle
      state :routed
      state :optimized
      state :orchestrated
      state :fanned
      state :done

      transition :route_step, from: :idle, to: :routed do
        route :missing_router_agent,
              routes: { done: :finish },
              confidence_threshold: 0.5,
              fallback: :finish
      end

      transition :optimize_step, from: :idle, to: :optimized do
        optimize generator: :missing_generator_agent,
                 evaluator: :missing_evaluator_agent,
                 max_rounds: 1,
                 evaluator_schema: schema
      end

      transition :orchestrate_step, from: :idle, to: :orchestrated do
        orchestrate orchestrator: :missing_orchestrator_agent,
                    worker: :missing_worker_agent,
                    max_workers: 2,
                    max_delegation_rounds: 1,
                    task_schema: schema,
                    worker_output_schema: schema,
                    final_output_schema: schema
      end

      transition :fanout_step, from: :idle, to: :fanned do
        fan_out branches: {
          research: :missing_research_agent,
          review: :missing_review_agent
        }
      end

      transition :finish, from: :routed, to: :done
    end

    report = workflow.runtime_readiness

    expect(report.status).to eq(:not_ready)
    expect(report.errors.map(&:target)).to include(
      :missing_router_agent,
      :missing_generator_agent,
      :missing_evaluator_agent,
      :missing_orchestrator_agent,
      :missing_worker_agent,
      :missing_research_agent,
      :missing_review_agent
    )
    expect(report.metrics.fetch(:unresolved_agent_bindings_count)).to eq(7)
    expect(report.metrics.fetch(:fanout_branches_count)).to eq(2)
  end

  it "exposes optimizer and orchestrator contracts through graph inspection" do
    evaluator_schema = with_stubbed_class("SpecGraphOptimizationEvaluatorSchema") do
      def self.required_keys = %i[accept feedback]
    end
    task_schema = with_stubbed_class("SpecGraphOrchestrationTaskSchema") do
      def self.required_keys = %i[task_id input]
    end
    worker_output_schema = with_stubbed_class("SpecGraphOrchestrationWorkerOutputSchema") do
      def self.required_keys = %i[finding]
    end
    final_output_schema = with_stubbed_class("SpecGraphOrchestrationFinalOutputSchema") do
      def self.required_keys = %i[summary]
    end

    workflow = with_stubbed_class("SpecGraphRuntimeContractWorkflow", workflow_class) do
      initial_state :idle
      state :optimized
      state :orchestrated

      transition :improve, from: :idle, to: :optimized do
        optimize generator: :spec_graph_generator_agent,
                 evaluator: :spec_graph_evaluator_agent,
                 max_rounds: 3,
                 evaluator_schema: evaluator_schema,
                 improvement_threshold: 0.1,
                 evaluator_context: :inject_state,
                 before_eval: ->(_state, _context) {},
                 on_exhaustion: :return_last
      end

      transition :delegate, from: :optimized, to: :orchestrated do
        orchestrate orchestrator: :spec_graph_orchestrator_agent,
                    worker: :spec_graph_worker_agent,
                    max_workers: 4,
                    max_delegation_rounds: 2,
                    task_schema: task_schema,
                    worker_output_schema: worker_output_schema,
                    final_output_schema: final_output_schema
      end
    end

    report = workflow.validate_graph
    optimize = report.transitions.find { |transition| transition.name == :improve }.to_h.fetch(:optimization)
    orchestration = report.transitions.find { |transition| transition.name == :delegate }.to_h.fetch(:orchestration)

    expect(optimize).to include(
      generator: :spec_graph_generator_agent,
      evaluator: :spec_graph_evaluator_agent,
      max_rounds: 3,
      evaluator_schema: "SpecGraphOptimizationEvaluatorSchema",
      evaluator_context: :inject_state,
      improvement_threshold: 0.1,
      before_eval: :callable
    )
    expect(optimize.fetch(:evaluator_schema)).to be_frozen
    expect(optimize.fetch(:exit_modes)).to eq(
      exhaustion: :return_last,
      converged: :raise,
      threshold: :raise
    )
    expect(optimize.fetch(:output_contract).fetch(:evaluator_output)).to eq(
      required: { accept: :boolean },
      rejection_requires: %i[feedback],
      threshold_requires: %i[score],
      optional: %i[score converged]
    )
    expect(optimize.fetch(:resume_contract)).to include(
      granularity: :transition,
      round_checkpointing: false,
      idempotency_mode: :lax,
      in_flight_resume: :reruns_transition
    )

    expect(orchestration).to include(
      orchestrator: :spec_graph_orchestrator_agent,
      worker: :spec_graph_worker_agent,
      max_workers: 4,
      max_delegation_rounds: 2,
      task_schema: "SpecGraphOrchestrationTaskSchema",
      worker_output_schema: "SpecGraphOrchestrationWorkerOutputSchema",
      final_output_schema: "SpecGraphOrchestrationFinalOutputSchema",
      worker_dispatch: :serial
    )
    expect(orchestration.fetch(:decision_contract)).to eq(
      shape: :hash,
      exactly_one_of: %i[tasks final stop],
      tasks_limit: 4
    )
    expect(orchestration.fetch(:resume_contract)).to include(
      granularity: :transition,
      round_checkpointing: false,
      worker_checkpointing: false,
      idempotency_mode: :lax,
      in_flight_resume: :reruns_transition
    )
  end

  it "fails closed when model-required roles have no configured model" do
    agent_class = require_const("Smith::Agent")
    schema = Class.new { def self.required_keys = [] }

    %i[
      spec_graph_router_no_model_agent
      spec_graph_generator_no_model_agent
      spec_graph_evaluator_no_model_agent
      spec_graph_orchestrator_no_model_agent
      spec_graph_worker_no_model_agent
    ].each do |agent_name|
      with_stubbed_class("SpecGraph#{agent_name.to_s.split("_").map(&:capitalize).join}", agent_class) do
        register_as agent_name
      end
    end

    workflow = with_stubbed_class("SpecGraphRuntimeRequiredModelWorkflow", workflow_class) do
      initial_state :idle
      state :routed
      state :optimized
      state :orchestrated
      state :done

      transition :route_step, from: :idle, to: :routed do
        route :spec_graph_router_no_model_agent,
              routes: { done: :finish },
              confidence_threshold: 0.5,
              fallback: :finish
      end

      transition :optimize_step, from: :idle, to: :optimized do
        optimize generator: :spec_graph_generator_no_model_agent,
                 evaluator: :spec_graph_evaluator_no_model_agent,
                 max_rounds: 1,
                 evaluator_schema: schema
      end

      transition :orchestrate_step, from: :idle, to: :orchestrated do
        orchestrate orchestrator: :spec_graph_orchestrator_no_model_agent,
                    worker: :spec_graph_worker_no_model_agent,
                    max_workers: 2,
                    max_delegation_rounds: 1,
                    task_schema: schema,
                    worker_output_schema: schema,
                    final_output_schema: schema
      end

      transition :finish, from: :routed, to: :done
    end

    report = workflow.runtime_readiness

    expect(report.status).to eq(:not_ready)
    expect(report.errors.map(&:code)).to all(eq(:agent_without_required_model))
    expect(report.metrics.fetch(:required_model_missing_count)).to eq(5)
  end

  it "projects nested workflow readiness diagnostics onto the parent transition" do
    child = with_stubbed_class("SpecGraphNestedNotReadyChild", workflow_class) do
      initial_state :idle
      state :done

      transition :child_start, from: :idle, to: :done do
        execute :missing_nested_agent
      end
    end

    parent = with_stubbed_class("SpecGraphNestedNotReadyParent", workflow_class) do
      initial_state :idle
      state :done

      transition :start, from: :idle, to: :done do
        workflow child
      end
    end

    report = parent.runtime_readiness

    expect(report.status).to eq(:not_ready)
    expect(report.errors.map(&:code)).to include(:nested_unresolved_agent_binding)
    expect(report.metrics.fetch(:unresolved_agent_bindings_count)).to eq(1)
    nested = report.errors.find { |diagnostic| diagnostic.code == :nested_unresolved_agent_binding }
    expect(nested.transition).to eq(:start)
    expect(nested.message).to include("Nested workflow SpecGraphNestedNotReadyChild")
  end

  it "folds nested workflow readiness metrics into parent metrics" do
    agent_class = require_const("Smith::Agent")

    with_stubbed_class("SpecGraphNestedReadyAgent", agent_class) do
      register_as :spec_graph_nested_ready_agent
      model "gpt-4.1-nano"
    end

    child = with_stubbed_class("SpecGraphNestedReadyChild", workflow_class) do
      initial_state :idle
      state :done

      transition :child_start, from: :idle, to: :done do
        execute :spec_graph_nested_ready_agent
      end
    end

    parent = with_stubbed_class("SpecGraphNestedReadyParent", workflow_class) do
      initial_state :idle
      state :done

      transition :start, from: :idle, to: :done do
        workflow child
      end
    end

    report = parent.runtime_readiness

    expect(report.status).to eq(:ready)
    expect(report.metrics).to include(
      direct_agent_bindings_count: 0,
      agent_bindings_count: 1,
      direct_nested_workflow_count: 1,
      nested_workflow_count: 1
    )
  end

  it "labels anonymous workflows in runtime readiness reports" do
    workflow = Class.new(workflow_class) do
      initial_state :idle
      state :done

      transition :start, from: :idle, to: :done do
        execute :missing_anonymous_agent
      end
    end

    report = workflow.runtime_readiness

    expect(report.workflow_class).to match(/\A#<Class:/)
    expect(report.errors.first.suggestion).to include(workflow.inspect)
  end
end
