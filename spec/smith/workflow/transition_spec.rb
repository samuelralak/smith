# frozen_string_literal: true

RSpec.describe Smith::Workflow::Transition do
  let(:schema) { Class.new { def self.required_keys = [] } }
  let(:child_workflow) do
    Class.new(Smith::Workflow) do
      initial_state :idle
      state :done
      transition :finish, from: :idle, to: :done
    end
  end

  def declarations
    @declarations ||= %i[execute route workflow optimize orchestrate fan_out compute].to_h do |name|
      [name, method(:"declare_#{name}")]
    end
  end

  def declare_execute(transition) = transition.execute(:agent)

  def declare_route(transition)
    transition.route(:router, routes: { ok: :finish }, confidence_threshold: 0.5, fallback: :finish)
  end

  def declare_workflow(transition) = transition.workflow(child_workflow)

  def declare_optimize(transition)
    transition.optimize(generator: :generator, evaluator: :evaluator, max_rounds: 1, evaluator_schema: schema)
  end

  def declare_orchestrate(transition)
    transition.orchestrate(
      orchestrator: :orchestrator,
      worker: :worker,
      max_workers: 1,
      max_delegation_rounds: 1,
      task_schema: schema,
      worker_output_schema: schema,
      final_output_schema: schema
    )
  end

  def declare_fan_out(transition) = transition.fan_out(branches: { one: :one })

  def declare_compute(transition) = transition.compute { |step| step.read_context(:noop) }

  it "rejects every ordered pair of mixed execution primitives" do
    declarations.each do |first_name, first|
      declarations.each do |second_name, second|
        next if first_name == second_name

        transition = described_class.new(:probe, from: :idle, to: :done)
        first.call(transition)
        original = execution_snapshot(transition)

        expect { second.call(transition) }
          .to raise_error(
            Smith::WorkflowError,
            "transition cannot declare both #{primitive_label(second_name)} and #{primitive_label(first_name)}"
          ), "accepted #{first_name} then #{second_name}"
        expect(execution_snapshot(transition)).to eq(original)
      end
    end
  end

  it "rejects repeated declarations without replacing the original contract" do
    declarations.each do |name, declaration|
      transition = described_class.new(:probe, from: :idle, to: :done)
      declaration.call(transition)
      original = execution_snapshot(transition)

      expect { declaration.call(transition) }
        .to raise_error(Smith::WorkflowError, /#{name}.*more than once/)
      expect(execution_snapshot(transition)).to eq(original)
    end
  end

  it "applies duplicate protection to the run and fanout aliases" do
    deterministic = described_class.new(:deterministic, from: :idle, to: :done)
    deterministic.run { |step| step.read_context(:noop) }
    expect { deterministic.run { |step| step.read_context(:noop) } }
      .to raise_error(Smith::WorkflowError, /run more than once/)

    fanout = described_class.new(:fanout, from: :idle, to: :done)
    fanout.fanout(branches: { one: :one })
    expect { fanout.fanout(branches: { two: :two }) }
      .to raise_error(Smith::WorkflowError, /fan_out more than once/)
  end

  it "rejects dead on_success metadata on routed transitions in either order" do
    route = ->(transition) { declare_route(transition) }
    success = ->(transition) { transition.on_success(:finish) }

    [[route, success], [success, route]].each do |first, second|
      transition = described_class.new(:route, from: :idle, to: :done)
      first.call(transition)

      expect { second.call(transition) }
        .to raise_error(Smith::WorkflowError, /routed transitions cannot declare on_success/)
    end
  end

  it "does not retain a partial route declaration after normalization fails" do
    transition = described_class.new(:probe, from: :idle, to: :done)

    expect do
      transition.route(:router, routes: {}, confidence_threshold: 0.5, fallback: :finish)
    end.to raise_error(Smith::WorkflowError, /routes must not be empty/)

    expect { transition.execute(:agent) }.not_to raise_error
    expect(transition.agent_name).to eq(:agent)
    expect(transition.router_config).to be_nil
  end

  it "does not retain a partial optimizer declaration after normalization fails" do
    transition = described_class.new(:probe, from: :idle, to: :done)

    expect do
      transition.optimize(generator: :generator, evaluator: " ", max_rounds: 1, evaluator_schema: schema)
    end.to raise_error(Smith::WorkflowError, /optimizer evaluator agent must not be blank/)

    expect { transition.execute(:agent) }.not_to raise_error
    expect(transition.optimization_config).to be_nil
  end

  it "does not retain an oversized static parallel declaration" do
    original_limit = Smith.config.parallel_branch_limit
    Smith.config.parallel_branch_limit = 2
    transition = described_class.new(:probe, from: :idle, to: :done)

    expect do
      transition.execute(:agent, parallel: true, count: 3)
    end.to raise_error(Smith::WorkflowError, /exceeds configured limit 2/)
    expect { transition.execute(:replacement) }.not_to raise_error
    expect(transition.agent_name).to eq(:replacement)
  ensure
    Smith.config.parallel_branch_limit = original_limit
  end

  it "keeps every failed execution declaration atomic" do
    invalid_declarations.each do |name, declaration|
      transition = described_class.new(:probe, from: :idle, to: :done)

      expect { declaration.call(transition) }
        .to raise_error(Smith::WorkflowError), "accepted invalid #{name} declaration"
      expect(execution_snapshot(transition).values.compact).to be_empty
      expect { transition.execute(:replacement) }.not_to raise_error
      expect(transition.agent_name).to eq(:replacement)
    end
  end

  def invalid_declarations
    %i[execute route workflow optimize orchestrate fan_out compute].to_h do |name|
      [name, method(:"declare_invalid_#{name}")]
    end
  end

  def declare_invalid_execute(transition) = transition.execute(" ")

  def declare_invalid_route(transition)
    transition.route(:router, routes: {}, confidence_threshold: 0.5, fallback: :finish)
  end

  def declare_invalid_workflow(transition) = transition.workflow(Object)

  def declare_invalid_optimize(transition)
    transition.optimize(generator: :generator, evaluator: " ", max_rounds: 1, evaluator_schema: schema)
  end

  def declare_invalid_orchestrate(transition)
    transition.orchestrate(
      orchestrator: :orchestrator,
      worker: " ",
      max_workers: 1,
      max_delegation_rounds: 1,
      task_schema: schema,
      worker_output_schema: schema,
      final_output_schema: schema
    )
  end

  def declare_invalid_fan_out(transition) = transition.fan_out(branches: { one: :agent, two: :agent })

  def declare_invalid_compute(transition) = transition.compute(routes: %i[finish finish]) { :done }

  def execution_snapshot(transition)
    {
      agent_name: transition.agent_name,
      agent_opts: transition.agent_opts,
      router_config: transition.router_config,
      workflow_class: transition.workflow_class,
      optimization_config: transition.optimization_config,
      orchestrator_config: transition.orchestrator_config,
      fanout_config: transition.fanout_config,
      deterministic_block: transition.deterministic_block,
      deterministic_kind: transition.deterministic_kind,
      deterministic_routes: transition.deterministic_routes
    }
  end

  def primitive_label(name)
    name == :compute ? "compute/run" : name.to_s
  end
end
