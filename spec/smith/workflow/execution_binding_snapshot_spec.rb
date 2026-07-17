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

  it "captures composite agent bindings from one registry epoch" do
    original_a = agent_class
    original_b = agent_class
    replacement_a = agent_class
    replacement_b = agent_class
    Smith::Agent::Registry.register(:branch_a, original_a)
    Smith::Agent::Registry.register(:branch_b, original_b)
    workflow_class = Class.new(Smith::Workflow)
    transition = Smith::Workflow::Transition.new(:fanout, from: :start, to: :done) do
      fan_out branches: { a: :branch_a, b: :branch_b }
    end
    first_fetch = Queue.new
    continue_capture = Queue.new
    writer_started = Queue.new
    fetch_count = 0

    allow(Smith::Agent::RegistryBinding).to receive(:new).and_wrap_original do |original, **options|
      binding = original.call(**options)
      fetch_count += 1
      if fetch_count == 1
        first_fetch << true
        continue_capture.pop
      end
      binding
    end

    capture = Thread.new { described_class.capture(transition, workflow_class:) }
    first_fetch.pop
    replacement = Dry::Container.new
    replacement.register(:branch_a, replacement_a, call: false)
    replacement.register(:branch_b, replacement_b, call: false)
    writer = Thread.new do
      writer_started << true
      Smith::Agent::Registry.merge(replacement) { |_key, _old, new| new }
    end
    writer_started.pop

    expect(writer.join(0.05)).to be_nil
    continue_capture << true
    snapshot = capture.value
    writer.join

    expect(
      snapshot.fetch!(:branch_a, workflow_class:, transition_name: :fanout, role: :fanout_agent)
    ).to equal(original_a)
    expect(
      snapshot.fetch!(:branch_b, workflow_class:, transition_name: :fanout, role: :fanout_agent)
    ).to equal(original_b)
  end

  it "rejects lazy agent bindings without executing their callbacks" do
    callback_ran = false
    Smith::Agent::Registry.register(:lazy_branch) do
      callback_ran = true
      agent_class
    end
    transition = Smith::Workflow::Transition.new(:branch, from: :start, to: :done) do
      execute :lazy_branch
    end

    expect do
      described_class.capture(transition, workflow_class: Class.new(Smith::Workflow))
    end.to raise_error(Smith::WorkflowError, /unresolved agent :lazy_branch/)
    expect(callback_ran).to be(false)
  end
end
