# frozen_string_literal: true

RSpec.describe Smith::Workflow::SplitStepPersistence::ExecutionBindingSnapshot do
  def agent_class
    Class.new(Smith::Agent)
  end

  it "captures all agent dependencies of a composite transition exactly once" do
    schema = Class.new do
      def self.required_keys = []
    end
    bindings = {
      primary: agent_class,
      branch_a: agent_class,
      branch_b: agent_class,
      generator: agent_class,
      evaluator: agent_class,
      orchestrator: agent_class,
      worker: agent_class
    }
    bindings.each { |name, klass| Smith::Agent::Registry.register(name, klass) }

    transitions = [
      Smith::Workflow::Transition.new(:primary, from: :start, to: :done) { execute :primary },
      Smith::Workflow::Transition.new(:fanout, from: :start, to: :done) do
        fan_out branches: { a: :branch_a, b: :branch_b }
      end,
      Smith::Workflow::Transition.new(:optimizer, from: :start, to: :done) do
        optimize(
          generator: :generator,
          evaluator: :evaluator,
          max_rounds: 1,
          evaluator_schema: Object.new
        )
      end,
      Smith::Workflow::Transition.new(:orchestrator, from: :start, to: :done) do
        orchestrate(
          orchestrator: :orchestrator,
          worker: :worker,
          max_workers: 1,
          max_delegation_rounds: 1,
          task_schema: schema,
          worker_output_schema: schema,
          final_output_schema: schema
        )
      end
    ]

    transitions.each do |transition|
      snapshot = described_class.capture(transition, workflow_class: Class.new(Smith::Workflow))
      names = case transition.name
              when :primary then %i[primary]
              when :fanout then %i[branch_a branch_b]
              when :optimizer then %i[generator evaluator]
              else %i[orchestrator worker]
              end

      names.each do |name|
        expect(
          snapshot.fetch!(name, workflow_class: Smith::Workflow, transition_name: transition.name, role: :agent)
        ).to equal(bindings.fetch(name))
      end
    end
  end

  it "captures bindings reachable through a nested workflow and terminates nested cycles" do
    original = agent_class
    Smith::Agent::Registry.register(:nested_agent, original)
    parent = Class.new(Smith::Workflow)
    child = Class.new(Smith::Workflow) do
      initial_state :start
      state :done
      transition(:answer, from: :start, to: :done) { execute :nested_agent }
    end
    parent.initial_state :start
    parent.state :done
    parent.transition(:child, from: :start, to: :done) { workflow child }
    child.state :parent
    child.transition(:parent, from: :done, to: :parent) { workflow parent }

    snapshot = described_class.capture(parent.find_transition(:child), workflow_class: parent)
    Smith::Agent::Registry.delete(:nested_agent)
    Smith::Agent::Registry.register(:nested_agent, agent_class)

    expect(
      snapshot.fetch!(:nested_agent, workflow_class: child, transition_name: :answer, role: :agent)
    ).to equal(original)
  end

  it "rejects nested workflow definition replacement after authorization" do
    child = Class.new(Smith::Workflow) do
      initial_state :start
      state :done
      transition(:answer, from: :start, to: :done) { compute { "original" } }
    end
    parent = Class.new(Smith::Workflow) do
      initial_state :start
      state :done
      transition(:child, from: :start, to: :done) { workflow child }
    end
    snapshot = described_class.capture(parent.find_transition(:child), workflow_class: parent)

    child.transition(:answer, from: :start, to: :done) { compute { "replacement" } }

    expect do
      snapshot.verify_workflow!(child)
    end.to raise_error(Smith::WorkflowError, /nested workflow definition changed/)
  end
end
