# frozen_string_literal: true

RSpec.describe "Smith::Workflow durable composite execution" do
  let(:adapter) { Smith::PersistenceAdapters::Memory.new }

  def register_composite_agent(name, agent = Class.new(Smith::Agent))
    agent.execution_identity(Digest::SHA256.hexdigest("spec-composite-agent:#{name}"))
    Smith::Agent::Registry.register(name, agent)
    agent
  end

  def prepare_composite(workflow_class, key)
    workflow = workflow_class.new
    workflow.prepare_persisted_step!(key, adapter: adapter)
    dispatch = workflow.claim_prepared_step_dispatch!
    preparation = workflow.prepare_composite_step!
    [dispatch, preparation]
  end

  def recover(workflow_class, dispatch)
    recovery = Smith::Workflow::PreparedStepRecovery.not_started(dispatch)
    workflow_class.recover_prepared_step(recovery, adapter: adapter)
  end

  def execute_branches(workflow_class, dispatch, preparation)
    preparation.plan.branches.map do |branch|
      workflow = recover(workflow_class, dispatch)
      execution = preparation.plan.execution_for(branch)
      workflow.execute_prepared_composite_branch!(
        execution:,
        input: preparation.input
      )
    end
  end

  def reduce(workflow_class, dispatch, preparation, outcomes, primary_failure: nil)
    workflow = recover(workflow_class, dispatch)
    result = workflow.reduce_prepared_composite_step!(
      plan: preparation.plan,
      input: preparation.input,
      outcomes:,
      primary_failure:
    )
    [workflow, result]
  end

  def prepare_authorized_composite(workflow, authorization)
    Smith::Workflow::SplitStepPersistence::CompositePreparation
      .instance_method(:prepare_authorized_composite_step!)
      .bind_call(workflow, authorization)
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

  def reduce_authorized_composite(workflow, authorization, **attributes)
    Smith::Workflow::SplitStepPersistence::CompositeReductionExecution
      .instance_method(:reduce_authorized_composite_step!)
      .bind_call(workflow, authorization, **attributes)
  end

  def empty_effects
    Smith::Workflow::Composite::Effects.new(
      usage_entries: [],
      tool_results: [],
      budget_consumed: {}
    )
  end

  def usage_effect(usage_id: SecureRandom.uuid, agent_name: "composite_agent")
    {
      usage_id:,
      agent_name:,
      model: "test-model",
      input_tokens: 2,
      output_tokens: 3,
      cost: 0.01,
      attempt_kind: "primary",
      recorded_at: Time.now.utc.iso8601
    }
  end

  it "exposes a scoped composite lifecycle without public authority handoff" do
    workflow = Smith::Workflow.new

    expect(workflow).to respond_to(:prepare_composite_step!)
    expect(workflow).to respond_to(:execute_prepared_composite_branch!)
    expect(workflow).to respond_to(:reduce_prepared_composite_step!)
    expect(workflow).not_to respond_to(:prepare_authorized_composite_step!)
    expect(workflow).not_to respond_to(:authorize_prepared_composite_branch_execution!)
    expect(workflow).not_to respond_to(:execute_authorized_composite_branch!)
    expect(workflow).not_to respond_to(:reduce_authorized_composite_step!)
  end

  it "keeps indexed fan-out lookups inside the composite execution boundary" do
    workflow_class = Class.new(Smith::Workflow) do
      initial_state :idle
      state :done
      transition(:finish, from: :idle, to: :done) do
        fan_out branches: { review: :reviewer }
      end
    end
    transition = workflow_class.find_transition(:finish)

    expect(transition).not_to respond_to(:fetch_fanout_agent!)
    expect(transition).not_to respond_to(:fetch_fanout_branch!)
    expect(transition.private_methods).to include(:fetch_fanout_agent!, :fetch_fanout_branch!)
  end

  it "round-trips and executes an ordered same-agent composite" do
    register_composite_agent(:composite_parallel_agent)
    workflow_class = stub_const("SpecCompositeParallelWorkflow", Class.new(Smith::Workflow) do
      definition_digest Digest::SHA256.hexdigest("composite-parallel")
      idempotency_mode :strict
      initial_state :idle
      state :done
      transition(:finish, from: :idle, to: :done) do
        execute :composite_parallel_agent, parallel: true, count: 4
      end
    end)
    dispatch, prepared = prepare_composite(workflow_class, "composite:parallel")
    plan = Smith::Workflow::Composite::Plan.deserialize(prepared.plan.serialize)
    input = Smith::Workflow::Composite::Input.deserialize(prepared.input.serialize)
    preparation = Smith::Workflow::Composite::Preparation.new(plan:, input:)

    outcomes = execute_branches(workflow_class, dispatch, preparation).map do |outcome|
      Smith::Workflow::Composite::BranchOutcome.deserialize(outcome.serialize)
    end
    workflow, result = reduce(workflow_class, dispatch, preparation, outcomes)

    expect(plan.branches.map(&:ordinal)).to eq([0, 1, 2, 3])
    expect(plan.branches).to be_frozen
    expect(plan.branches.first.budget).to be_frozen
    expect(plan.resume_policy).to eq(:incomplete_only)
    expect(plan.retry_policy).to eq(:none)
    expect(workflow).to be_done
    expect(result).to be_succeeded
    expect(result.step.fetch(:output).map { _1.fetch("branch") }).to eq([0, 1, 2, 3])
    workflow.persist!(adapter: adapter)
    workflow.complete_persisted_step!
    restored = workflow_class.from_state(JSON.parse(JSON.generate(workflow.to_state)))
    expect(restored.run!.output).to eq(result.step.fetch(:output))
  ensure
    Smith::Agent::Registry.delete(:composite_parallel_agent)
  end

  it "preserves declared heterogeneous fanout order" do
    %i[zeta alpha middle].each do |name|
      register_composite_agent(:"composite_#{name}")
    end
    workflow_class = stub_const("SpecCompositeFanoutWorkflow", Class.new(Smith::Workflow) do
      definition_digest Digest::SHA256.hexdigest("composite-fanout")
      idempotency_mode :strict
      initial_state :idle
      state :done
      transition(:finish, from: :idle, to: :done) do
        fan_out branches: {
          zeta: :composite_zeta,
          alpha: :composite_alpha,
          middle: :composite_middle
        }
      end
    end)
    dispatch, preparation = prepare_composite(workflow_class, "composite:fanout")

    outcomes = execute_branches(workflow_class, dispatch, preparation)
    workflow, result = reduce(workflow_class, dispatch, preparation, outcomes)

    expect(preparation.plan.branches.map(&:key)).to eq(%w[zeta alpha middle])
    expect(workflow).to be_done
    expect(result.step.fetch(:output).map { _1.fetch("branch") }).to eq(%w[zeta alpha middle])
  ensure
    %i[zeta alpha middle].each { Smith::Agent::Registry.delete(:"composite_#{_1}") }
  end

  it "reduces a host-committed primary branch failure through on_failure" do
    successful = Class.new(Smith::Agent)
    failing = Class.new(Smith::Agent) { model "gpt-5-mini" }
    register_composite_agent(:composite_successful, successful)
    register_composite_agent(:composite_failing, failing)
    allow(failing).to receive(:chat).and_raise(Smith::AgentError, "provider secret must not cross transport")
    workflow_class = stub_const("SpecCompositeFailureWorkflow", Class.new(Smith::Workflow) do
      definition_digest Digest::SHA256.hexdigest("composite-failure")
      idempotency_mode :strict
      initial_state :idle
      state :done
      state :failed
      transition(:finish, from: :idle, to: :done) do
        fan_out branches: { successful: :composite_successful, failing: :composite_failing }
        on_failure :fail
      end
    end)
    dispatch, preparation = prepare_composite(workflow_class, "composite:failure")
    outcomes = execute_branches(workflow_class, dispatch, preparation)
    failed = outcomes.find(&:failed?)

    workflow, result = reduce(
      workflow_class,
      dispatch,
      preparation,
      outcomes,
      primary_failure: failed.branch_key
    )

    expect(failed.error.family).to eq("agent_error")
    expect(failed.serialize).not_to include("provider secret")
    expect(workflow).to be_failed
    expect(result).to be_failed
    expect(result.error).to be_a(Smith::Workflow::Composite::BranchFailure)
    expect(result.error.branch_key).to eq("failing")
    workflow.persist!(adapter: adapter)
    workflow.complete_persisted_step!
    restored = workflow_class.from_state(JSON.parse(JSON.generate(workflow.to_state)))
    restored_error = restored.run!.last_error
    expect(restored_error).to be_a(Smith::Workflow::Composite::BranchFailure)
    expect(restored_error.branch_key).to eq("failing")
    expect(restored_error.error_class).to eq("Smith::AgentError")
    expect(restored_error.error_family).to eq("agent_error")
    expect(restored_error.retryable).to be(true)
  ensure
    Smith::Agent::Registry.delete(:composite_successful)
    Smith::Agent::Registry.delete(:composite_failing)
  end

  it "requires the primary failure to identify a failed branch" do
    register_composite_agent(:composite_primary_agent)
    workflow_class = stub_const("SpecCompositePrimaryWorkflow", Class.new(Smith::Workflow) do
      definition_digest Digest::SHA256.hexdigest("composite-primary")
      idempotency_mode :strict
      initial_state :idle
      state :done
      transition(:finish, from: :idle, to: :done) do
        execute :composite_primary_agent, parallel: true, count: 2
      end
    end)
    dispatch, preparation = prepare_composite(workflow_class, "composite:primary")
    outcomes = execute_branches(workflow_class, dispatch, preparation)

    expect do
      reduce(workflow_class, dispatch, preparation, outcomes, primary_failure: "0")
    end.to raise_error(ArgumentError, /must be absent/)
  ensure
    Smith::Agent::Registry.delete(:composite_primary_agent)
  end

  it "rejects missing and duplicated outcomes in linear validation" do
    register_composite_agent(:composite_validation_agent)
    workflow_class = stub_const("SpecCompositeValidationWorkflow", Class.new(Smith::Workflow) do
      definition_digest Digest::SHA256.hexdigest("composite-validation")
      idempotency_mode :strict
      initial_state :idle
      state :done
      transition(:finish, from: :idle, to: :done) do
        execute :composite_validation_agent, parallel: true, count: 2
      end
    end)
    dispatch, preparation = prepare_composite(workflow_class, "composite:validation")
    outcomes = execute_branches(workflow_class, dispatch, preparation)

    expect do
      reduce(workflow_class, dispatch, preparation, outcomes.first(1))
    end.to raise_error(ArgumentError, /count does not match/)
    expect do
      reduce(workflow_class, dispatch, preparation, [outcomes.first, outcomes.first])
    end.to raise_error(ArgumentError, /duplicated/)
  ensure
    Smith::Agent::Registry.delete(:composite_validation_agent)
  end

  it "resolves a callable parallel count only during planning" do
    calls = 0
    register_composite_agent(:composite_callable_agent)
    workflow_class = stub_const("SpecCompositeCallableWorkflow", Class.new(Smith::Workflow) do
      definition_digest Digest::SHA256.hexdigest("composite-callable")
      idempotency_mode :strict
      initial_state :idle
      state :done
      transition(:finish, from: :idle, to: :done) do
        execute :composite_callable_agent, parallel: true, count: lambda { |_context|
          calls += 1
          3
        }
      end
    end)
    dispatch, preparation = prepare_composite(workflow_class, "composite:callable")

    outcomes = execute_branches(workflow_class, dispatch, preparation)
    workflow, = reduce(workflow_class, dispatch, preparation, outcomes)

    expect(workflow).to be_done
    expect(preparation.plan.branches.length).to eq(3)
    expect(calls).to eq(1)
  ensure
    Smith::Agent::Registry.delete(:composite_callable_agent)
  end

  it "fails closed before planning a composite transition with retry semantics" do
    register_composite_agent(:composite_retry_agent)
    workflow_class = stub_const("SpecCompositeRetryWorkflow", Class.new(Smith::Workflow) do
      definition_digest Digest::SHA256.hexdigest("composite-retry")
      idempotency_mode :strict
      initial_state :idle
      state :done
      transition(:finish, from: :idle, to: :done) do
        execute :composite_retry_agent, parallel: true, count: 2
        retry_on StandardError, attempts: 2
      end
    end)
    workflow = workflow_class.new
    workflow.prepare_persisted_step!("composite:retry", adapter: adapter)
    workflow.claim_prepared_step_dispatch!
    authorization = workflow.authorize_prepared_step_execution!

    expect do
      prepare_authorized_composite(workflow, authorization)
    end.to raise_error(Smith::WorkflowError, /retries are not supported/)
  ensure
    Smith::Agent::Registry.delete(:composite_retry_agent)
  end

  it "merges usage and budget effects once during reduction" do
    agent = Class.new(Smith::Agent) do
      model "gpt-5-mini"
    end
    register_composite_agent(:composite_budget_agent, agent)
    allow(agent).to receive(:chat) do
      Object.new.tap do |chat|
        chat.define_singleton_method(:add_message) { |_message| nil }
        chat.define_singleton_method(:complete) do
          Struct.new(:content, :input_tokens, :output_tokens).new("ok", 7, 5)
        end
      end
    end
    workflow_class = stub_const("SpecCompositeBudgetWorkflow", Class.new(Smith::Workflow) do
      definition_digest Digest::SHA256.hexdigest("composite-budget")
      idempotency_mode :strict
      budget total_tokens: 100
      initial_state :idle
      state :done
      transition(:finish, from: :idle, to: :done) do
        execute :composite_budget_agent, parallel: true, count: 3
      end
    end)
    dispatch, preparation = prepare_composite(workflow_class, "composite:budget")

    outcomes = execute_branches(workflow_class, dispatch, preparation)
    workflow, result = reduce(workflow_class, dispatch, preparation, outcomes)

    expect(result).to be_succeeded
    expect(workflow.ledger.consumed).to eq(total_tokens: 36)
    expect(workflow.to_state.fetch(:usage_entries).length).to eq(3)
    expect(workflow.to_state.fetch(:total_tokens)).to eq(36)
  ensure
    Smith::Agent::Registry.delete(:composite_budget_agent)
  end

  it "rejects unknown transport attributes instead of silently discarding them" do
    register_composite_agent(:composite_exact_agent)
    workflow_class = stub_const("SpecCompositeExactWorkflow", Class.new(Smith::Workflow) do
      definition_digest Digest::SHA256.hexdigest("composite-exact")
      idempotency_mode :strict
      initial_state :idle
      state :done
      transition(:finish, from: :idle, to: :done) do
        execute :composite_exact_agent, parallel: true, count: 2
      end
    end)
    _dispatch, preparation = prepare_composite(workflow_class, "composite:exact")

    expect do
      Smith::Workflow::Composite::Plan.deserialize(preparation.plan.to_h.merge(untrusted: true))
    end.to raise_error(ArgumentError, /unknown attributes: untrusted/)
  ensure
    Smith::Agent::Registry.delete(:composite_exact_agent)
  end

  it "rejects oversized branch collections before deserializing branch entries" do
    register_composite_agent(:composite_bound_agent)
    workflow_class = stub_const("SpecCompositeBoundWorkflow", Class.new(Smith::Workflow) do
      definition_digest Digest::SHA256.hexdigest("composite-bound")
      idempotency_mode :strict
      initial_state :idle
      state :done
      transition(:finish, from: :idle, to: :done) do
        execute :composite_bound_agent, parallel: true, count: 2
      end
    end)
    _dispatch, preparation = prepare_composite(workflow_class, "composite:bound")
    payload = preparation.plan.to_h.merge(
      branches: Array.new(Smith::Workflow::Composite::Plan::MAX_BRANCHES + 1) { {} }
    )

    expect(Smith::Workflow::Composite::Branch).not_to receive(:deserialize)
    expect do
      Smith::Workflow::Composite::Plan.deserialize(payload)
    end.to raise_error(ArgumentError, /branch count is outside the transport limit/)
  ensure
    Smith::Agent::Registry.delete(:composite_bound_agent)
  end

  it "revalidates the configured branch limit in every recovered worker" do
    register_composite_agent(:composite_relimit_agent)
    workflow_class = stub_const("SpecCompositeRelimitWorkflow", Class.new(Smith::Workflow) do
      definition_digest Digest::SHA256.hexdigest("composite-relimit")
      idempotency_mode :strict
      initial_state :idle
      state :done
      transition(:finish, from: :idle, to: :done) do
        execute :composite_relimit_agent, parallel: true, count: 3
      end
    end)
    dispatch, preparation = prepare_composite(workflow_class, "composite:relimit")
    previous_limit = Smith.config.parallel_branch_limit
    Smith.config.parallel_branch_limit = 2
    workflow = recover(workflow_class, dispatch)
    execution = preparation.plan.execution_for(preparation.plan.branches.first)
    expect do
      authorize_composite_branch(workflow, execution, preparation.input)
    end.to raise_error(Smith::WorkflowError, /branch count exceeds configured limit 2/)
  ensure
    Smith.config.parallel_branch_limit = previous_limit if previous_limit
    Smith::Agent::Registry.delete(:composite_relimit_agent)
  end

  it "uses core Hash and Array traversal for transport containers" do
    register_composite_agent(:composite_hostile_agent)
    workflow_class = stub_const("SpecCompositeHostileWorkflow", Class.new(Smith::Workflow) do
      definition_digest Digest::SHA256.hexdigest("composite-hostile")
      idempotency_mode :strict
      initial_state :idle
      state :done
      transition(:finish, from: :idle, to: :done) do
        execute :composite_hostile_agent, parallel: true, count: 2
      end
    end)
    dispatch, preparation = prepare_composite(workflow_class, "composite:hostile")
    hostile_array_class = Class.new(Array) do
      def each(*) = raise("overridden Array#each ran")
      def length = 2**63
    end
    hostile_array = hostile_array_class.new
    Array.instance_method(:concat).bind_call(hostile_array, preparation.plan.to_h.fetch(:branches))
    hostile_hash = Class.new(Hash) do
      def each_pair(*) = raise("overridden Hash#each_pair ran")
    end.new.merge!(preparation.plan.to_h.merge(branches: hostile_array))
    plan = Smith::Workflow::Composite::Plan.deserialize(hostile_hash)
    outcomes = execute_branches(
      workflow_class,
      dispatch,
      Smith::Workflow::Composite::Preparation.new(plan:, input: preparation.input)
    )
    hostile_outcomes_class = Class.new(Array) do
      def each(*) = raise("overridden outcome Array#each ran")
      def length = 2**63
    end
    hostile_outcomes = hostile_outcomes_class.new
    Array.instance_method(:concat).bind_call(hostile_outcomes, outcomes)

    workflow, result = reduce(workflow_class, dispatch, preparation, hostile_outcomes)

    expect(result).to be_succeeded
    expect(workflow).to be_done
  ensure
    Smith::Agent::Registry.delete(:composite_hostile_agent)
  end

  it "rejects malformed usage and tool effects at the transport boundary" do
    expect do
      Smith::Workflow::Composite::Effects.new(
        usage_entries: [usage_effect.merge(untrusted: true)],
        tool_results: [],
        budget_consumed: {}
      )
    end.to raise_error(ArgumentError, /usage entry attributes are invalid/)

    expect do
      Smith::Workflow::Composite::Effects.new(
        usage_entries: [],
        tool_results: [{ tool: "lookup" }],
        budget_consumed: {}
      )
    end.to raise_error(ArgumentError, /tool result attributes are invalid/)
  end

  it "rejects oversized, deeply nested, and non-finite transport values" do
    max_bytes = Smith::Workflow::MessageValueNormalizer::MAX_BYTES
    too_deep = nil
    (Smith::Workflow::MessageValueNormalizer::MAX_DEPTH + 1).times { too_deep = [too_deep] }

    expect do
      Smith::Workflow::Composite::Input.build(agent_messages: "x" * (max_bytes + 1), session_messages: [])
    end.to raise_error(Smith::WorkflowError, /exceeds maximum bytes/)
    expect do
      Smith::Workflow::Composite::Input.build(agent_messages: too_deep, session_messages: [])
    end.to raise_error(Smith::WorkflowError, /exceeds maximum depth/)
    expect do
      Smith::Workflow::Composite::Effects.new(
        usage_entries: [],
        tool_results: [],
        budget_consumed: { total_tokens: Float::NAN }
      )
    end.to raise_error(Smith::WorkflowError, /non-finite Float/)
  end

  it "rejects plans produced for a different execution semantics version" do
    register_composite_agent(:composite_semantics_agent)
    workflow_class = stub_const("SpecCompositeSemanticsWorkflow", Class.new(Smith::Workflow) do
      definition_digest Digest::SHA256.hexdigest("composite-semantics")
      idempotency_mode :strict
      initial_state :idle
      state :done
      transition(:finish, from: :idle, to: :done) do
        execute :composite_semantics_agent, parallel: true, count: 2
      end
    end)
    _dispatch, preparation = prepare_composite(workflow_class, "composite:semantics")

    expect do
      Smith::Workflow::Composite::Plan.deserialize(
        preparation.plan.to_h.merge(execution_semantics_version: "1")
      )
    end.to raise_error(ArgumentError, /execution semantics do not match/)
  ensure
    Smith::Agent::Registry.delete(:composite_semantics_agent)
  end

  it "aggregates heterogeneous budget dimensions in one pass" do
    consumptions = Array.new(1_000) { |index| { "dimension_#{index}" => 1 } }
    consumptions << { "shared" => 0.1 }
    consumptions << { shared: 0.2 }

    totals = Smith::Workflow::Composite::BudgetMath.sum(consumptions)

    expect(totals.length).to eq(1_001)
    expect(totals.fetch("dimension_999")).to eq(1)
    expect(totals.fetch("shared")).to be_within(0.000_001).of(0.3)
    expect(totals).to be_frozen
  end

  it "isolates exact decimal aggregation from host BigDecimal precision" do
    previous_limit = BigDecimal.limit
    BigDecimal.limit(2)
    consumptions = Array.new(3) { { total_cost: 0.123 } }
    effects = Smith::Workflow::Composite::Effects.new(
      usage_entries: Array.new(3) { usage_effect.merge(usage_id: SecureRandom.uuid, cost: 0.123) },
      tool_results: [],
      budget_consumed: {}
    )

    expect(Smith::Workflow::Composite::BudgetMath.sum(consumptions)).to eq("total_cost" => 0.369)
    expect(effects.total_cost).to be_within(0.000_001).of(0.369)
    expect(BigDecimal.limit).to eq(2)
  ensure
    BigDecimal.limit(previous_limit)
  end

  it "rejects aggregate output before consuming prepared execution authority" do
    register_composite_agent(:composite_envelope_agent)
    workflow_class = stub_const("SpecCompositeEnvelopeWorkflow", Class.new(Smith::Workflow) do
      definition_digest Digest::SHA256.hexdigest("composite-envelope")
      idempotency_mode :strict
      initial_state :idle
      state :done
      transition(:finish, from: :idle, to: :done) do
        execute :composite_envelope_agent, parallel: true, count: 5
      end
    end)
    dispatch, preparation = prepare_composite(workflow_class, "composite:envelope")
    outcomes = execute_branches(workflow_class, dispatch, preparation)
    oversized = "x" * 900_000
    outcomes = outcomes.map.with_index do |outcome, ordinal|
      branch = preparation.plan.branches.fetch(ordinal)
      Smith::Workflow::Composite::BranchOutcome.succeeded(
        plan_digest: preparation.plan.plan_digest,
        branch:,
        output: oversized,
        effects: outcome.effects
      )
    end
    workflow = recover(workflow_class, dispatch)
    authorization = workflow.authorize_prepared_step_execution!

    expect do
      reduce_authorized_composite(
        workflow,
        authorization,
        plan: preparation.plan,
        input: preparation.input,
        outcomes:
      )
    end.to raise_error(Smith::WorkflowError, /aggregate output exceeds maximum bytes/)
    expect { workflow.release_prepared_step_execution!(authorization) }.not_to raise_error
    expect(workflow).to be_prepared_persisted_step
  ensure
    Smith::Agent::Registry.delete(:composite_envelope_agent)
  end

  it "validates only the selected descriptor in each branch worker" do
    register_composite_agent(:composite_linear_agent)
    workflow_class = stub_const("SpecCompositeLinearWorkflow", Class.new(Smith::Workflow) do
      definition_digest Digest::SHA256.hexdigest("composite-linear")
      idempotency_mode :strict
      initial_state :idle
      state :done
      transition(:finish, from: :idle, to: :done) do
        execute :composite_linear_agent, parallel: true, count: 100
      end
    end)
    dispatch, preparation = prepare_composite(workflow_class, "composite:linear")
    workflow = recover(workflow_class, dispatch)
    branch = preparation.plan.branches.fetch(73)
    execution = preparation.plan.execution_for(branch)
    authorization = authorize_composite_branch(workflow, execution, preparation.input)
    allow(Smith::Workflow::Composite::Branch).to receive(:build).and_call_original

    outcome = execute_authorized_composite_branch(workflow, authorization, execution, preparation.input)

    expect(outcome).to be_succeeded
    expect(Smith::Workflow::Composite::Branch).to have_received(:build).once
  ensure
    Smith::Agent::Registry.delete(:composite_linear_agent)
  end

  it "preserves the prepared execution membrane across composite internals" do
    register_composite_agent(:composite_collision_agent)
    base = Class.new(Smith::Workflow) do
      definition_digest Digest::SHA256.hexdigest("composite-collision")
      idempotency_mode :strict
      initial_state :idle
      state :done
      transition(:finish, from: :idle, to: :done) do
        execute :composite_collision_agent, parallel: true, count: 2
      end
    end
    workflow_class = stub_const("SpecCompositeCollisionWorkflow", Class.new(base) do
      def prepare_composite_step!(*) = raise("public subclass collision")
      def execute_prepared_composite_branch!(*) = raise("public subclass collision")
      def reduce_prepared_composite_step!(*) = raise("public subclass collision")

      private

      def perform_authorized_prepared_step_execution!(*) = raise("subclass collision")
      def validate_composite_authorization!(*) = raise("subclass collision")
      def validate_composite_branch_plan!(*) = raise("subclass collision")
      def execute_composite_branch(*) = raise("subclass collision")
      def apply_composite_reduction!(*) = raise("subclass collision")
    end)
    dispatch, preparation = prepare_composite(workflow_class, "composite:collision")
    outcomes = execute_branches(workflow_class, dispatch, preparation)

    workflow, result = reduce(workflow_class, dispatch, preparation, outcomes)

    expect(result).to be_succeeded
    expect(workflow).to be_done
  ensure
    Smith::Agent::Registry.delete(:composite_collision_agent)
  end

  it "preserves the prepared execution membrane across fan-out branch contracts" do
    register_composite_agent(:composite_collision_left)
    register_composite_agent(:composite_collision_right)
    base = Class.new(Smith::Workflow) do
      definition_digest Digest::SHA256.hexdigest("composite-fanout-collision")
      idempotency_mode :strict
      initial_state :idle
      state :done
      transition(:finish, from: :idle, to: :done) do
        fan_out branches: {
          left: :composite_collision_left,
          right: :composite_collision_right
        }
      end
    end
    workflow_class = stub_const("SpecCompositeFanoutCollisionWorkflow", Class.new(base) do
      private

      def fanout_branch_specs(*) = raise("subclass collision")
      def selected_fanout_branch_spec(*) = raise("subclass collision")
    end)
    dispatch, preparation = prepare_composite(workflow_class, "composite:fanout-collision")
    outcomes = execute_branches(workflow_class, dispatch, preparation)

    workflow, result = reduce(workflow_class, dispatch, preparation, outcomes)

    expect(result).to be_succeeded
    expect(workflow).to be_done
  ensure
    Smith::Agent::Registry.delete(:composite_collision_left)
    Smith::Agent::Registry.delete(:composite_collision_right)
  end

  it "preserves central retry classification in redacted branch failures" do
    agent_error = Smith::Workflow::Composite::ErrorEvidence.call(Smith::AgentError.new("provider unavailable"))
    deadline = Smith::Workflow::Composite::ErrorEvidence.call(Smith::DeadlineExceeded.new("deadline"))
    custom_error = Class.new(StandardError) do
      def retryable = raise("untrusted retryable accessor")
      def kind = raise("untrusted kind accessor")
    end.new("failed")
    custom = Smith::Workflow::Composite::ErrorEvidence.call(custom_error)
    failure = Smith::Workflow::Composite::BranchFailure.new(branch_key: "provider", error: agent_error)

    expect(agent_error.retryable).to be(true)
    expect(deadline.retryable).to be(true)
    expect(custom.retryable).to be(false)
    expect(custom.kind).to be_nil
    expect(Smith::Errors.retryable?(failure)).to be(false)
  end

  it "rejects aggregate token and cost overflow at the effects boundary" do
    max = Smith::Workflow::PreparedStep::MAX_COUNTER_VALUE
    token_entries = Array.new(2) do
      usage_effect.merge(usage_id: SecureRandom.uuid, input_tokens: max, output_tokens: 0)
    end
    cost_entries = Array.new(2) do
      usage_effect.merge(usage_id: SecureRandom.uuid, cost: Float::MAX)
    end

    expect do
      Smith::Workflow::Composite::Effects.new(
        usage_entries: token_entries,
        tool_results: [],
        budget_consumed: {}
      )
    end.to raise_error(ArgumentError, /token total exceeds/)
    expect do
      Smith::Workflow::Composite::Effects.new(
        usage_entries: cost_entries,
        tool_results: [],
        budget_consumed: {}
      )
    end.to raise_error(ArgumentError, /cost total must be finite/)
  end

  it "returns a typed failed outcome when successful output cannot cross transport" do
    agent = Class.new(Smith::Agent) { model "gpt-5-mini" }
    register_composite_agent(:composite_output_agent, agent)
    allow(agent).to receive(:chat) do
      Object.new.tap do |chat|
        chat.define_singleton_method(:add_message) { |_message| nil }
        chat.define_singleton_method(:complete) do
          Struct.new(:content, :input_tokens, :output_tokens).new("x" * 1_100_000, 1, 1)
        end
      end
    end
    workflow_class = stub_const("SpecCompositeOutputWorkflow", Class.new(Smith::Workflow) do
      definition_digest Digest::SHA256.hexdigest("composite-output")
      idempotency_mode :strict
      initial_state :idle
      state :done
      transition(:finish, from: :idle, to: :done) do
        execute :composite_output_agent, parallel: true, count: 1
      end
    end)
    dispatch, preparation = prepare_composite(workflow_class, "composite:output")

    outcome = execute_branches(workflow_class, dispatch, preparation).first

    expect(outcome).to be_failed
    expect(outcome.error.family).to eq("workflow_error")
    expect(outcome.effects.usage_entries.length).to eq(1)
  ensure
    Smith::Agent::Registry.delete(:composite_output_agent)
  end

  it "rejects output whose JSON encoding exceeds the transport envelope" do
    expect do
      Smith::Workflow::Composite::Input.build(
        agent_messages: "\n" * 524_289,
        session_messages: []
      )
    end.to raise_error(ArgumentError, /encoded bytes/)
  end

  it "requires the canonical complete outcome shape during deserialization" do
    register_composite_agent(:composite_shape_agent)
    workflow_class = stub_const("SpecCompositeShapeWorkflow", Class.new(Smith::Workflow) do
      definition_digest Digest::SHA256.hexdigest("composite-shape")
      idempotency_mode :strict
      initial_state :idle
      state :done
      transition(:finish, from: :idle, to: :done) do
        execute :composite_shape_agent, parallel: true, count: 1
      end
    end)
    dispatch, preparation = prepare_composite(workflow_class, "composite:shape")
    payload = execute_branches(workflow_class, dispatch, preparation).first.to_h
    payload.delete(:error)

    expect do
      Smith::Workflow::Composite::BranchOutcome.deserialize(payload)
    end.to raise_error(ArgumentError, /missing attributes: error/)
  ensure
    Smith::Agent::Registry.delete(:composite_collision_agent)
  end

  it "rejects the transport branch ceiling before allocating descriptors" do
    previous_limit = Smith.config.parallel_branch_limit
    Smith.config.parallel_branch_limit = Smith::Workflow::Composite::Plan::MAX_BRANCHES + 1
    register_composite_agent(:composite_ceiling_agent)
    workflow_class = stub_const("SpecCompositeCeilingWorkflow", Class.new(Smith::Workflow) do
      definition_digest Digest::SHA256.hexdigest("composite-ceiling")
      idempotency_mode :strict
      initial_state :idle
      state :done
      transition(:finish, from: :idle, to: :done) do
        execute :composite_ceiling_agent,
                parallel: true,
                count: Smith::Workflow::Composite::Plan::MAX_BRANCHES + 1
      end
    end)
    workflow = workflow_class.new
    workflow.prepare_persisted_step!("composite:ceiling", adapter: adapter)
    workflow.claim_prepared_step_dispatch!
    authorization = workflow.authorize_prepared_step_execution!
    allow(Smith::Workflow::Composite::Branch).to receive(:build).and_call_original

    expect do
      prepare_authorized_composite(workflow, authorization)
    end.to raise_error(ArgumentError, /transport limit/)
    expect(Smith::Workflow::Composite::Branch).not_to have_received(:build)
  ensure
    Smith.config.parallel_branch_limit = previous_limit if previous_limit
    Smith::Agent::Registry.delete(:composite_ceiling_agent)
  end

  it "captures only the selected heterogeneous binding for each branch worker" do
    names = Array.new(100) { |index| :"composite_binding_#{index}" }
    names.each { |name| register_composite_agent(name) }
    branches = names.each_with_index.to_h { |name, index| [:"branch_#{index}", name] }
    workflow_class = stub_const("SpecCompositeBindingWorkflow", Class.new(Smith::Workflow) do
      definition_digest Digest::SHA256.hexdigest("composite-binding")
      idempotency_mode :strict
      initial_state :idle
      state :done
      transition(:finish, from: :idle, to: :done) { fan_out branches: branches }
    end)
    dispatch, preparation = prepare_composite(workflow_class, "composite:binding")
    request_counts = []
    allow(Smith::Agent::Registry).to receive(:capture_bindings!).and_wrap_original do |method, requests|
      request_counts << requests.length
      method.call(requests)
    end
    branch = preparation.plan.branches.fetch(73)
    worker = recover(workflow_class, dispatch)
    execution = preparation.plan.execution_for(branch)

    authorization = authorize_composite_branch(worker, execution, preparation.input)

    expect(request_counts).to eq([1])
    worker.release_prepared_step_execution!(authorization)
  ensure
    names&.each { |name| Smith::Agent::Registry.delete(name) }
  end

  it "shares one first-step artifact namespace across branch workers and reduction" do
    original_store = Smith.config.artifact_store
    writes = []
    backend = Object.new
    backend.define_singleton_method(:store) do |_data, content_type:, execution_namespace:|
      writes << { content_type:, execution_namespace: }
      "artifact-#{writes.length}"
    end
    backend.define_singleton_method(:fetch) { |_ref| nil }
    backend.define_singleton_method(:expired) { |**| [] }
    Smith.configure { |config| config.artifact_store = backend }
    agent = Class.new(Smith::Agent) do
      model "gpt-5-mini"

      define_method(:after_completion) do |result, _context|
        { artifact_ref: Smith.artifacts.store(result, content_type: "text/plain") }
      end
    end
    register_composite_agent(:composite_artifact_agent, agent)
    allow(agent).to receive(:chat) do
      Object.new.tap do |chat|
        chat.define_singleton_method(:add_message) { |_message| nil }
        chat.define_singleton_method(:complete) do
          Struct.new(:content, :input_tokens, :output_tokens).new("artifact body", 1, 1)
        end
      end
    end
    workflow_class = stub_const("SpecCompositeArtifactWorkflow", Class.new(Smith::Workflow) do
      definition_digest Digest::SHA256.hexdigest("composite-artifact")
      idempotency_mode :strict
      initial_state :idle
      state :done
      transition(:finish, from: :idle, to: :done) do
        execute :composite_artifact_agent, parallel: true, count: 2
      end
    end)
    dispatch, preparation = prepare_composite(workflow_class, "composite:artifact")
    outcomes = execute_branches(workflow_class, dispatch, preparation)

    reduced, result = reduce(workflow_class, dispatch, preparation, outcomes)

    expect(result).to be_succeeded
    expect(writes.map { _1.fetch(:execution_namespace) }.uniq).to eq([preparation.plan.execution_namespace])
    expect(reduced.to_state.fetch(:execution_namespace)).to eq(preparation.plan.execution_namespace)
    expect(result.step.fetch(:output).map { _1.dig("output", "artifact_ref") }).to eq(
      [
        "#{preparation.plan.execution_namespace}:artifact-1",
        "#{preparation.plan.execution_namespace}:artifact-2"
      ]
    )
  ensure
    Smith.configure { |config| config.artifact_store = original_store }
    Smith::Agent::Registry.delete(:composite_artifact_agent)
  end

  it "derives retryability only from Smith's approved error classification" do
    hostile_class = Class.new(StandardError)
    hostile_class.define_method(:retryable) { true }
    hostile = hostile_class.new("retry me")

    evidence = Smith::Workflow::Composite::ErrorEvidence.call(hostile)

    expect(evidence.retryable).to be(false)
    failure = Smith::Workflow::Composite::BranchFailure.new(branch_key: "hostile", error: evidence)
    expect(Smith::Errors.retryable?(failure)).to be(false)
  end

  it "allocates disjoint branch budgets and rejects forged consumption before authority is consumed" do
    register_composite_agent(:composite_budget_agent)
    workflow_class = stub_const("SpecCompositeBudgetWorkflow", Class.new(Smith::Workflow) do
      definition_digest Digest::SHA256.hexdigest("composite-budget")
      idempotency_mode :strict
      budget total_tokens: 1
      initial_state :idle
      state :done
      transition(:finish, from: :idle, to: :done) do
        execute :composite_budget_agent, parallel: true, count: 2
      end
    end)
    dispatch, preparation = prepare_composite(workflow_class, "composite:budget")
    expect(preparation.plan.branches.sum { _1.budget.fetch("total_tokens") }).to eq(1)
    outcomes = preparation.plan.branches.map do |branch|
      effects = Smith::Workflow::Composite::Effects.new(
        usage_entries: [usage_effect(agent_name: branch.agent).merge(input_tokens: 1, output_tokens: 0)],
        tool_results: [],
        budget_consumed: { total_tokens: 1 }
      )
      Smith::Workflow::Composite::BranchOutcome.succeeded(
        plan_digest: preparation.plan.plan_digest, branch:, output: nil, effects:
      )
    end
    workflow = recover(workflow_class, dispatch)
    authorization = workflow.authorize_prepared_step_execution!

    expect do
      reduce_authorized_composite(
        workflow, authorization, plan: preparation.plan, input: preparation.input, outcomes:
      )
    end.to raise_error(ArgumentError, /consumption exceeds its envelope/)
    expect(workflow.release_prepared_step_execution!(authorization)).to equal(workflow)
    expect(workflow.ledger.consumed).to be_empty
  ensure
    Smith::Agent::Registry.delete(:composite_budget_agent)
  end

  it "returns a typed failed outcome while preserving safe effects when a tool capture is invalid" do
    agent = Class.new(Smith::Agent) { model "gpt-5-mini" }
    register_composite_agent(:composite_capture_agent, agent)
    allow(agent).to receive(:chat) do
      Object.new.tap do |chat|
        chat.define_singleton_method(:add_message) { |_message| nil }
        chat.define_singleton_method(:complete) do
          Smith::Tool.current_tool_result_collector.call(tool: "invalid", captured: Object.new)
          Struct.new(:content, :input_tokens, :output_tokens).new("ok", 1, 1)
        end
      end
    end
    workflow_class = stub_const("SpecCompositeCaptureWorkflow", Class.new(Smith::Workflow) do
      definition_digest Digest::SHA256.hexdigest("composite-capture")
      idempotency_mode :strict
      initial_state :idle
      state :done
      transition(:finish, from: :idle, to: :done) do
        execute :composite_capture_agent, parallel: true, count: 1
      end
    end)
    dispatch, preparation = prepare_composite(workflow_class, "composite:capture")

    outcome = execute_branches(workflow_class, dispatch, preparation).first

    expect(outcome).to be_failed
    expect(outcome.effects.usage_entries.length).to eq(1)
    expect(outcome.effects.tool_results).to be_empty
  ensure
    Smith::Agent::Registry.delete(:composite_capture_agent)
  end

  it "preserves host-defined tool captures through ordered reduction" do
    register_composite_agent(:composite_tool_agent)
    workflow_class = stub_const("SpecCompositeToolWorkflow", Class.new(Smith::Workflow) do
      definition_digest Digest::SHA256.hexdigest("composite-tool")
      idempotency_mode :strict
      initial_state :idle
      state :done
      transition(:finish, from: :idle, to: :done) do
        execute :composite_tool_agent, parallel: true, count: 2
      end
    end)
    dispatch, preparation = prepare_composite(workflow_class, "composite:tool")
    outcomes = execute_branches(workflow_class, dispatch, preparation)
    branch = preparation.plan.branches.first
    effects = Smith::Workflow::Composite::Effects.new(
      usage_entries: [],
      tool_results: [{ tool: "catalog_lookup", captured: { ids: [3, 5, 8] } }],
      budget_consumed: {}
    )
    outcomes[branch.ordinal] = Smith::Workflow::Composite::BranchOutcome.succeeded(
      plan_digest: preparation.plan.plan_digest,
      branch:,
      output: outcomes.fetch(branch.ordinal).output,
      effects:
    )

    workflow, result = reduce(workflow_class, dispatch, preparation, outcomes)

    expect(result).to be_succeeded
    expect(workflow.to_state.fetch(:tool_results)).to eq(
      [{ tool: "catalog_lookup", captured: { "ids" => [3, 5, 8] } }]
    )
  ensure
    Smith::Agent::Registry.delete(:composite_tool_agent)
  end

  it "restores the prepared conversation exactly once before appending the aggregate" do
    register_composite_agent(:composite_session_agent)
    workflow_class = stub_const("SpecCompositeSessionWorkflow", Class.new(Smith::Workflow) do
      definition_digest Digest::SHA256.hexdigest("composite-session")
      idempotency_mode :strict
      initial_state :idle
      state :done
      transition(:finish, from: :idle, to: :done) do
        execute :composite_session_agent, parallel: true, count: 2
      end
    end)
    workflow = workflow_class.new
    workflow.append_session_messages!(role: :user, content: "Preserve this turn")
    workflow.prepare_persisted_step!("composite:session", adapter: adapter)
    dispatch = workflow.claim_prepared_step_dispatch!
    authorization = workflow.authorize_prepared_step_execution!
    preparation = prepare_authorized_composite(workflow, authorization)
    workflow.release_prepared_step_execution!(authorization)
    outcomes = execute_branches(workflow_class, dispatch, preparation)

    reduced, result = reduce(workflow_class, dispatch, preparation, outcomes)
    messages = reduced.session_messages

    expect(result).to be_succeeded
    expect(messages.first).to eq("content" => "Preserve this turn", "role" => "user")
    expect(messages.count { (_1["role"] || _1[:role]).to_s == "user" }).to eq(1)
    expect(messages.count { (_1["role"] || _1[:role]).to_s == "assistant" }).to eq(1)
  ensure
    Smith::Agent::Registry.delete(:composite_session_agent)
  end

  it "rejects replayed usage without partially applying tool or budget effects" do
    register_composite_agent(:composite_atomic_agent)
    workflow_class = stub_const("SpecCompositeAtomicWorkflow", Class.new(Smith::Workflow) do
      definition_digest Digest::SHA256.hexdigest("composite-atomic")
      idempotency_mode :strict
      budget total_tokens: 100
      initial_state :idle
      state :done
      transition(:finish, from: :idle, to: :done) do
        execute :composite_atomic_agent, parallel: true, count: 2
      end
    end)
    dispatch, preparation = prepare_composite(workflow_class, "composite:atomic")
    outcomes = execute_branches(workflow_class, dispatch, preparation)
    branch = preparation.plan.branches.first
    usage = usage_effect(agent_name: branch.agent)
    effects = Smith::Workflow::Composite::Effects.new(
      usage_entries: [usage],
      tool_results: [{ tool: "side_effect", captured: { applied: false } }],
      budget_consumed: { total_tokens: 5 }
    )
    outcomes[branch.ordinal] = Smith::Workflow::Composite::BranchOutcome.succeeded(
      plan_digest: preparation.plan.plan_digest,
      branch:,
      output: nil,
      effects:
    )
    workflow = recover(workflow_class, dispatch)
    workflow.instance_variable_get(:@usage_entries) << Smith::Workflow::UsageEntry.from_h(usage)
    workflow.instance_variable_set(:@total_tokens, 5)
    workflow.instance_variable_set(:@total_cost, 0.01)
    authorization = workflow.authorize_prepared_step_execution!

    expect do
      reduce_authorized_composite(
        workflow,
        authorization,
        plan: preparation.plan,
        input: preparation.input,
        outcomes:
      )
    end.to raise_error(Smith::WorkflowError, /usage entry was already applied/)
    expect(workflow.to_state.fetch(:usage_entries).length).to eq(1)
    expect(workflow.to_state.fetch(:tool_results)).to be_empty
    expect(workflow.ledger.consumed).to be_empty
    expect(workflow.to_state.fetch(:total_tokens)).to eq(5)
    expect(workflow.to_state.fetch(:total_cost)).to eq(0.01)
    expect(workflow.release_prepared_step_execution!(authorization)).to equal(workflow)
  ensure
    Smith::Agent::Registry.delete(:composite_atomic_agent)
  end

  it "rejects cumulative token and cost overflow before authority is consumed" do
    register_composite_agent(:composite_total_agent)
    workflow_class = stub_const("SpecCompositeTotalWorkflow", Class.new(Smith::Workflow) do
      definition_digest Digest::SHA256.hexdigest("composite-total")
      idempotency_mode :strict
      initial_state :idle
      state :done
      transition(:finish, from: :idle, to: :done) do
        execute :composite_total_agent, parallel: true, count: 1
      end
    end)
    dispatch, preparation = prepare_composite(workflow_class, "composite:total")
    branch = preparation.plan.branches.first

    token_workflow = recover(workflow_class, dispatch)
    token_workflow.instance_variable_set(:@total_tokens, Smith::Workflow::PreparedStep::MAX_COUNTER_VALUE)
    token_effects = Smith::Workflow::Composite::Effects.new(
      usage_entries: [usage_effect(agent_name: branch.agent).merge(cost: 0.0, input_tokens: 1, output_tokens: 0)],
      tool_results: [],
      budget_consumed: {}
    )
    token_outcome = Smith::Workflow::Composite::BranchOutcome.succeeded(
      plan_digest: preparation.plan.plan_digest, branch:, output: nil, effects: token_effects
    )
    token_authorization = token_workflow.authorize_prepared_step_execution!

    expect do
      reduce_authorized_composite(
        token_workflow,
        token_authorization,
        plan: preparation.plan,
        input: preparation.input,
        outcomes: [token_outcome]
      )
    end.to raise_error(Smith::WorkflowError, /token total exceeds/)
    expect(token_workflow.release_prepared_step_execution!(token_authorization)).to equal(token_workflow)

    cost_workflow = recover(workflow_class, dispatch)
    cost_workflow.instance_variable_set(:@total_cost, Float::MAX)
    cost_effects = Smith::Workflow::Composite::Effects.new(
      usage_entries: [
        usage_effect(agent_name: branch.agent).merge(cost: Float::MAX, input_tokens: 0, output_tokens: 0)
      ],
      tool_results: [],
      budget_consumed: {}
    )
    cost_outcome = Smith::Workflow::Composite::BranchOutcome.succeeded(
      plan_digest: preparation.plan.plan_digest, branch:, output: nil, effects: cost_effects
    )
    cost_authorization = cost_workflow.authorize_prepared_step_execution!

    expect do
      reduce_authorized_composite(
        cost_workflow,
        cost_authorization,
        plan: preparation.plan,
        input: preparation.input,
        outcomes: [cost_outcome]
      )
    end.to raise_error(Smith::WorkflowError, /cost total must be finite/)
    expect(cost_workflow.release_prepared_step_execution!(cost_authorization)).to equal(cost_workflow)
  ensure
    Smith::Agent::Registry.delete(:composite_total_agent)
  end
end
