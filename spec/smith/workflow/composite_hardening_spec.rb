# frozen_string_literal: true

RSpec.describe "Smith::Workflow composite durability hardening" do
  let(:adapter) { Smith::PersistenceAdapters::Memory.new }

  def register_agent(name, identity: name.to_s, agent: Class.new(Smith::Agent))
    agent.execution_identity(Digest::SHA256.hexdigest("composite-hardening:#{identity}"))
    Smith::Agent::Registry.register(name, agent)
    agent
  end

  def parallel_workflow(agent_name, count:, budget: nil, superclass: Smith::Workflow)
    workflow_class = Class.new(superclass) do
      definition_digest Digest::SHA256.hexdigest("composite-hardening:#{agent_name}:#{count}")
      idempotency_mode :strict
      budget(**budget) if budget
      initial_state :idle
      state :done
      transition(:finish, from: :idle, to: :done) do
        execute agent_name, parallel: true, count:
      end
    end
    constant_name = agent_name.to_s.split("_").map(&:capitalize).join
    stub_const("Spec#{constant_name}Workflow", workflow_class)
  end

  def prepare(workflow_class, key)
    workflow = workflow_class.new
    workflow.prepare_persisted_step!(key, adapter:)
    dispatch = workflow.claim_prepared_step_dispatch!
    preparation = workflow.prepare_composite_step!
    [dispatch, preparation]
  end

  def recover(workflow_class, dispatch)
    recovery = Smith::Workflow::PreparedStepRecovery.not_started(dispatch)
    workflow_class.recover_prepared_step(recovery, adapter:)
  end

  def empty_effects
    Smith::Workflow::Composite::Effects.new(
      usage_entries: [], tool_results: [], budget_consumed: {}
    )
  end

  def authorize_composite_branch(workflow, execution, input)
    Smith::Workflow::SplitStepPersistence::CompositeBranchAuthorization
      .instance_method(:authorize_prepared_composite_branch_execution!)
      .bind_call(workflow, execution:, input:)
  end

  def execute_authorized_composite_branch(workflow, authorization, execution, input)
    Smith::Workflow::SplitStepPersistence::CompositeBranchExecution
      .instance_method(:execute_authorized_composite_branch!)
      .bind_call(workflow, authorization, execution:, input:)
  end

  it "binds process-local authority to one exact branch execution envelope" do
    name = :composite_exact_authority
    agent = register_agent(name)
    workflow_class = parallel_workflow(name, count: 2)
    dispatch, preparation = prepare(workflow_class, "composite:exact-authority")
    first_execution = preparation.plan.execution_for(preparation.plan.branches.fetch(0))
    second_execution = preparation.plan.execution_for(preparation.plan.branches.fetch(1))
    worker = recover(workflow_class, dispatch)
    authorization = authorize_composite_branch(worker, first_execution, preparation.input)
    expect(agent).not_to receive(:chat)

    expect do
      execute_authorized_composite_branch(worker, authorization, second_execution, preparation.input)
    end.to raise_error(Smith::WorkflowError, /authorization does not match execution/)
    expect { worker.release_prepared_step_execution!(authorization) }
      .to raise_error(Smith::WorkflowError, /no longer active/)
  ensure
    Smith::Agent::Registry.delete(name)
  end

  it "releases branch authority when interruption lands before authorization handoff" do
    name = :composite_interrupted_authorization
    register_agent(name)
    workflow_class = parallel_workflow(name, count: 1)
    dispatch, preparation = prepare(workflow_class, "composite:interrupted-authorization")
    execution = preparation.plan.execution_for(preparation.plan.branches.first)
    worker = recover(workflow_class, dispatch)
    activated = Queue.new
    resume_activation = Queue.new
    authorization_module = Smith::Workflow::SplitStepPersistence::ExecutionAuthorization
    original = authorization_module.instance_method(:activate_split_step_execution_authorization!)
    authorization_module.module_eval do
      define_method(:activate_split_step_execution_authorization!) do |authorization, verification_token|
        original.bind_call(self, authorization, verification_token)
        activated << true
        resume_activation.pop
      end
      private :activate_split_step_execution_authorization!
    end
    thread = Thread.new do
      worker.execute_prepared_composite_branch!(execution:, input: preparation.input)
    rescue Interrupt
      nil
    end
    thread.report_on_exception = false

    Timeout.timeout(2) { activated.pop }
    thread.raise(Interrupt, "interrupt authorization handoff")
    Timeout.timeout(2) { Thread.pass until thread.pending_interrupt?(Interrupt) }
    resume_activation << true
    Timeout.timeout(2) { thread.join }
    authorization_module.module_eval do
      define_method(:activate_split_step_execution_authorization!, original)
      private :activate_split_step_execution_authorization!
    end

    expect(worker.instance_variable_get(:@split_step_phase)).to eq(:dispatch_claimed)
    authorization = authorize_composite_branch(worker, execution, preparation.input)
    expect { worker.release_prepared_step_execution!(authorization) }.not_to raise_error
  ensure
    resume_activation << true if resume_activation
    thread&.kill
    authorization_module&.module_eval do
      define_method(:activate_split_step_execution_authorization!, original)
      private :activate_split_step_execution_authorization!
    end
    Smith::Agent::Registry.delete(name)
  end

  it "rejects an agent implementation replacement after planning" do
    name = :composite_replaced_binding
    register_agent(name, identity: "original")
    workflow_class = parallel_workflow(name, count: 1)
    dispatch, preparation = prepare(workflow_class, "composite:replaced-binding")
    Smith::Agent::Registry.delete(name)
    register_agent(name, identity: "replacement")
    execution = preparation.plan.execution_for(preparation.plan.branches.first)
    worker = recover(workflow_class, dispatch)

    expect do
      authorize_composite_branch(worker, execution, preparation.input)
    end.to raise_error(Smith::WorkflowError, /branch does not match the prepared transition/)
    expect(worker).to be_prepared_persisted_step
  ensure
    Smith::Agent::Registry.delete(name)
  end

  it "cannot bypass durable dispatch verification through a subclass collision" do
    name = :composite_dispatch_collision
    register_agent(name)
    base = parallel_workflow(name, count: 1)
    workflow_class = stub_const("SpecCompositeDispatchCollisionSubclass", Class.new(base) do
      private

      def verify_claimed_split_step_execution!(*) = self
    end)
    key = "composite:dispatch-collision"
    dispatch, preparation = prepare(workflow_class, key)
    worker = recover(workflow_class, dispatch)
    adapter.delete(key)
    execution = preparation.plan.execution_for(preparation.plan.branches.first)

    expect do
      authorize_composite_branch(worker, execution, preparation.input)
    end.to raise_error(Smith::PersistencePayloadConflict)
  ensure
    Smith::Agent::Registry.delete(name)
  end

  it "does not intern unknown JSON attribute names" do
    unknown = "untrusted_#{SecureRandom.hex(16)}"
    refute_symbol = -> { Symbol.all_symbols.none? { _1.to_s == unknown } }
    expect(refute_symbol.call).to be(true)

    expect do
      Smith::Workflow::Composite::Error.deserialize(
        "class_name" => "RuntimeError",
        "family" => "other",
        "retryable" => false,
        "kind" => nil,
        unknown => true
      )
    end.to raise_error(ArgumentError, /unknown attributes/)
    expect(refute_symbol.call).to be(true)
  end

  it "does not intern unknown transport enum values" do
    name = :composite_enum_safety
    register_agent(name)
    workflow_class = parallel_workflow(name, count: 1)
    _dispatch, preparation = prepare(workflow_class, "composite:enum-safety")
    branch = preparation.plan.branches.first
    execution = preparation.plan.execution_for(branch)
    outcome = Smith::Workflow::Composite::BranchOutcome.succeeded(
      plan_digest: preparation.plan.plan_digest,
      branch:,
      output: nil,
      effects: empty_effects
    )
    probes = [
      [Smith::Workflow::Composite::Plan, preparation.plan.to_h, :kind],
      [Smith::Workflow::Composite::BranchExecution, execution.to_h, :resume_policy],
      [Smith::Workflow::Composite::BranchOutcome, outcome.to_h, :status]
    ]

    probes.each do |payload_class, payload, attribute|
      hostile = "untrusted_enum_#{SecureRandom.hex(16)}"
      expect(Symbol.all_symbols.none? { _1.to_s == hostile }).to be(true)
      expect { payload_class.deserialize(payload.merge(attribute => hostile)) }.to raise_error(Dry::Struct::Error)
      expect(Symbol.all_symbols.none? { _1.to_s == hostile }).to be(true)
    end
  ensure
    Smith::Agent::Registry.delete(name)
  end

  it "streams outcome validation and stops before materializing an oversized aggregate" do
    name = :composite_streaming_outcomes
    register_agent(name)
    workflow_class = parallel_workflow(name, count: 6)
    _dispatch, preparation = prepare(workflow_class, "composite:streaming-outcomes")
    yielded = 0
    outcomes = Enumerator.new do |stream|
      preparation.plan.branches.each do |branch|
        yielded += 1
        stream << Smith::Workflow::Composite::BranchOutcome.succeeded(
          plan_digest: preparation.plan.plan_digest,
          branch:,
          output: "x" * 900_000,
          effects: empty_effects
        )
      end
    end

    expect do
      Smith::Workflow::Composite::Reducer.new(plan: preparation.plan, outcomes:).call
    end.to raise_error(Smith::WorkflowError, /aggregate output exceeds maximum bytes/)
    expect(yielded).to be < preparation.plan.branches.length
  ensure
    Smith::Agent::Registry.delete(name)
  end

  it "streams encoded effects validation before consuming every outcome" do
    name = :composite_streaming_effects
    register_agent(name)
    workflow_class = parallel_workflow(name, count: 4)
    _dispatch, preparation = prepare(workflow_class, "composite:streaming-effects")
    yielded = 0
    effects = Smith::Workflow::Composite::Effects.new(
      usage_entries: [],
      tool_results: [{ tool: "audit", captured: "x" * 600_000 }],
      budget_consumed: {}
    )
    outcomes = Enumerator.new do |stream|
      preparation.plan.branches.each do |branch|
        yielded += 1
        stream << Smith::Workflow::Composite::BranchOutcome.succeeded(
          plan_digest: preparation.plan.plan_digest,
          branch:,
          output: nil,
          effects:
        )
      end
    end

    expect do
      Smith::Workflow::Composite::Reducer.new(plan: preparation.plan, outcomes:).call
    end.to raise_error(Smith::WorkflowError, /aggregate effects exceeds maximum bytes/)
    expect(yielded).to be < preparation.plan.branches.length
  ensure
    Smith::Agent::Registry.delete(name)
  end

  it "fails closed when persisted branch failure details are incomplete or unknown" do
    valid = {
      branch_key: "reviewer",
      error_class: "Smith::AgentError",
      error_family: "agent_error",
      retryable: true,
      kind: nil
    }

    expect(Smith::Workflow::Composite::BranchFailure.from_details(valid).branch_key).to eq("reviewer")
    expect do
      Smith::Workflow::Composite::BranchFailure.from_details(valid.except(:error_class))
    end.to raise_error(ArgumentError, /missing required attributes/)
    expect do
      Smith::Workflow::Composite::BranchFailure.from_details(valid.merge(message: "invent me"))
    end.to raise_error(ArgumentError, /unknown attribute/)
  end

  it "keeps each worker envelope independent of total branch payload size" do
    name = :composite_compact_envelope
    register_agent(name)
    workflow_class = parallel_workflow(name, count: 1_000)
    _dispatch, preparation = prepare(workflow_class, "composite:compact-envelope")
    execution = preparation.plan.execution_for(preparation.plan.branches.fetch(731))

    expect(execution.branch_count).to eq(1_000)
    expect(execution.serialize.bytesize).to be < (preparation.plan.serialize.bytesize / 10)
    expect(Smith::Workflow::Composite::BranchExecution.deserialize(execution.serialize).digest).to eq(execution.digest)
  ensure
    Smith::Agent::Registry.delete(name)
  end

  it "rejects forged error retryability and untrusted error kinds" do
    expect do
      Smith::Workflow::Composite::Error.new(
        class_name: "RuntimeError", family: "other", retryable: true, kind: nil
      )
    end.to raise_error(ArgumentError, /retryability does not match/)

    hostile = Class.new(StandardError) { define_method(:kind) { "private-metadata" } }.new
    evidence = Smith::Workflow::Composite::ErrorEvidence.call(hostile)
    expect(evidence.kind).to be_nil
    expect(evidence.retryable).to be(false)
  end

  it "requires subclasses to declare their own execution identity" do
    parent = Class.new(Smith::Agent)
    parent.execution_identity(Digest::SHA256.hexdigest("parent-agent"))
    child = Class.new(parent)

    expect(parent.execution_identity).not_to be_nil
    expect(child.execution_identity).to be_nil
  end

  it "rejects scalar overflow before snapshotting tool effects" do
    baseline = Smith::Workflow::Composite::EffectsBaseline.new(
      usage_entries: [],
      tool_results: [],
      total_tokens: Smith::Workflow::PreparedStep::MAX_COUNTER_VALUE,
      total_cost: 0.0,
      ledger: nil,
      budget_consumed: {}
    )
    effects = Smith::Workflow::Composite::Effects.new(
      usage_entries: [
        {
          usage_id: SecureRandom.uuid,
          agent_name: "worker",
          model: "test",
          input_tokens: 1,
          output_tokens: 0,
          cost: 0.0,
          attempt_kind: "primary",
          recorded_at: Time.now.utc.iso8601
        }
      ],
      tool_results: [{ tool: "never_snapshot", captured: { value: 1 } }],
      budget_consumed: {}
    )
    snapshots = 0
    snapshotter = lambda do |value|
      snapshots += 1
      value
    end

    expect do
      Smith::Workflow::Composite::EffectsPreflight.new(effects:, baseline:, snapshotter:).call
    end.to raise_error(Smith::WorkflowError, /token total exceeds/)
    expect(snapshots).to eq(0)
  end
end
