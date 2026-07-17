# frozen_string_literal: true

RSpec.describe Smith::Workflow::PreparedStepExecutionAuthorization do
  let(:adapter) { Smith::PersistenceAdapters::Memory.new }
  let(:key) { "workflow:execution-authorization" }
  let(:definition_digest) { Digest::SHA256.hexdigest("execution-authorization-v1") }
  let(:workflow_class) do
    digest = definition_digest
    stub_const("SpecExecutionAuthorizationWorkflow", Class.new(Smith::Workflow) do
      definition_digest digest
      idempotency_mode :strict
      initial_state :idle
      state :done

      transition :finish, from: :idle, to: :done do
        compute { |step| step.write_context(:executed, true) }
      end
    end)
  end

  def claimed_workflow(klass = workflow_class, persistence_key = key)
    klass.new.tap do |workflow|
      workflow.prepare_persisted_step!(persistence_key, adapter: adapter)
      workflow.claim_prepared_step_dispatch!
    end
  end

  def execution_bindings(workflow)
    Smith::Workflow::SplitStepPersistence::ExecutionBindingSnapshot.capture(
      workflow.class.find_transition(:finish),
      workflow_class: workflow.class
    )
  end

  it "authorizes an exact committed dispatch without executing it" do
    workflow = claimed_workflow

    authorization = workflow.authorize_prepared_step_execution!

    expect(authorization).to be_a(described_class)
    expect(authorization.prepared_step).to equal(workflow.prepared_persisted_step)
    expect(authorization.dispatch_claim).to be_a(Smith::Workflow::PreparedStepDispatch)
    expect(authorization.dispatch_claim.prepared_step).to equal(authorization.prepared_step)
    expect(authorization).to be_frozen
    expect(workflow.state).to eq(:idle)
    expect(workflow.to_state.fetch(:step_count)).to eq(0)
  end

  it "consumes an active authorization exactly once" do
    workflow = claimed_workflow
    authorization = workflow.authorize_prepared_step_execution!

    result = workflow.execute_authorized_prepared_step!(authorization)

    expect(result).to be_a(Smith::Workflow::PreparedStepExecutionResult)
    expect(result).to be_succeeded
    expect(result.step).to include(transition: :finish, from: :idle, to: :done)
    expect(workflow).to be_done
    expect do
      workflow.execute_authorized_prepared_step!(authorization)
    end.to raise_error(Smith::WorkflowError, /no longer active/)
  end

  it "rejects a structurally equivalent authorization that Smith did not issue" do
    workflow = claimed_workflow
    authorization = workflow.authorize_prepared_step_execution!
    forged = described_class.new(
      prepared_step: authorization.prepared_step,
      dispatch_claim: authorization.dispatch_claim,
      execution_bindings: execution_bindings(workflow)
    )

    expect do
      workflow.execute_authorized_prepared_step!(forged)
    end.to raise_error(Smith::WorkflowError, /no longer active/)

    expect(workflow.execute_authorized_prepared_step!(authorization).step).to include(transition: :finish)
  end

  it "rejects an authorization issued by another workflow boundary" do
    first = claimed_workflow(workflow_class, "#{key}:first")
    second = claimed_workflow(workflow_class, "#{key}:second")
    authorization = first.authorize_prepared_step_execution!

    expect do
      second.execute_authorized_prepared_step!(authorization)
    end.to raise_error(Smith::WorkflowError, /no longer active/)

    expect(first.execute_authorized_prepared_step!(authorization).step).to include(transition: :finish)
  end

  it "releases unused process-local authority back to the exact dispatch claim" do
    workflow = claimed_workflow
    first = workflow.authorize_prepared_step_execution!

    expect(workflow).to be_prepared_persisted_step
    expect(workflow.release_prepared_step_execution!(first)).to equal(workflow)
    expect(workflow).to be_prepared_persisted_step

    second = workflow.authorize_prepared_step_execution!
    expect(second).not_to equal(first)
    expect do
      workflow.execute_authorized_prepared_step!(first)
    end.to raise_error(Smith::WorkflowError, /no longer active/)
    expect(workflow.execute_authorized_prepared_step!(second).step).to include(transition: :finish)
  end

  it "rejects duplicate release without changing the restored boundary" do
    workflow = claimed_workflow
    authorization = workflow.authorize_prepared_step_execution!
    workflow.release_prepared_step_execution!(authorization)

    expect do
      workflow.release_prepared_step_execution!(authorization)
    end.to raise_error(Smith::WorkflowError, /no longer active/)
    expect(workflow).to be_prepared_persisted_step
  end

  it "allows only one concurrent authorization claimant" do
    workflow = claimed_workflow
    gate = Queue.new
    results = 2.times.map do
      Thread.new do
        gate.pop
        workflow.authorize_prepared_step_execution!
      rescue StandardError => e
        e
      end
    end
    2.times { gate << true }
    values = results.map(&:value)

    expect(values.count { _1.is_a?(described_class) }).to eq(1)
    expect(values.count { _1.is_a?(Smith::WorkflowError) }).to eq(1)
  end

  it "does not let a losing authorizer revoke the active verifier" do
    workflow = claimed_workflow
    entered = Queue.new
    release = Queue.new
    fetches = 0
    allow(adapter).to receive(:fetch).and_wrap_original do |original, *arguments|
      fetches += 1
      if fetches == 1
        entered << true
        release.pop
      end
      original.call(*arguments)
    end
    winner = Thread.new { workflow.authorize_prepared_step_execution! }
    entered.pop

    expect do
      workflow.authorize_prepared_step_execution!
    end.to raise_error(Smith::WorkflowError, /no persisted step is prepared/)

    release << true
    authorization = winner.value
    expect(workflow.execute_authorized_prepared_step!(authorization).step).to include(transition: :finish)
  end

  it "linearizes release against execution and never performs both" do
    30.times do |index|
      execution_count = 0
      klass = Class.new(Smith::Workflow) do
        definition_digest Digest::SHA256.hexdigest("release-race-#{index}")
        idempotency_mode :strict
        initial_state :idle
        state :done
        transition(:finish, from: :idle, to: :done) { compute { execution_count += 1 } }
      end
      workflow = claimed_workflow(klass, "#{key}:race:#{index}")
      authorization = workflow.authorize_prepared_step_execution!
      gate = Queue.new
      operations = [
        Thread.new do
          gate.pop
          workflow.execute_authorized_prepared_step!(authorization)
        rescue StandardError => e
          e
        end,
        Thread.new do
          gate.pop
          workflow.release_prepared_step_execution!(authorization)
        rescue StandardError => e
          e
        end
      ]
      2.times { gate << true }
      values = operations.map(&:value)

      expect(values.count { _1.is_a?(Smith::WorkflowError) }).to eq(1)
      expect(execution_count).to eq(workflow.done? ? 1 : 0)
      expect(workflow).to be_prepared_persisted_step unless workflow.done?
    end
  end

  it "cannot release authority after transition work begins" do
    authorization = nil
    workflow = nil
    releasing_class = Class.new(Smith::Workflow) do
      definition_digest Digest::SHA256.hexdigest("release-after-start")
      idempotency_mode :strict
      initial_state :idle
      state :done
      state :failed
      transition :finish, from: :idle, to: :done do
        compute { workflow.release_prepared_step_execution!(authorization) }
        on_failure :fail
      end
    end
    workflow = claimed_workflow(releasing_class, "#{key}:release-after-start")
    authorization = workflow.authorize_prepared_step_execution!

    result = workflow.execute_authorized_prepared_step!(authorization)

    expect(result).to be_failed
    expect(result.error).to be_a(Smith::WorkflowError)
    expect(result.error.message).to match(/no longer active/)
    expect(workflow).not_to be_prepared_persisted_step
    expect(workflow.state).to eq(:failed)
  end

  it "fails authorization before execution when the durable dispatch is lost" do
    workflow = claimed_workflow
    adapter.delete(key)

    expect do
      workflow.authorize_prepared_step_execution!
    end.to raise_error(Smith::PersistencePayloadConflict)
    expect(workflow).not_to be_prepared_persisted_step
    expect(workflow.state).to eq(:idle)
  end

  it "keeps legacy strict workflows compatible without a dispatch claim" do
    legacy_class = Class.new(Smith::Workflow) do
      idempotency_mode :strict
      initial_state :idle
      state :done
      transition :finish, from: :idle, to: :done
    end
    workflow = legacy_class.new
    workflow.prepare_persisted_step!("#{key}:legacy", adapter: adapter)

    authorization = workflow.authorize_prepared_step_execution!

    expect(authorization.dispatch_claim).to be_nil
    expect(workflow.execute_authorized_prepared_step!(authorization).step).to include(transition: :finish, to: :done)
  end

  it "retains execute_prepared_step as the verified convenience boundary" do
    workflow = claimed_workflow

    step = workflow.execute_prepared_step!

    expect(step).to include(transition: :finish, to: :done)
    expect { step[:transition] = :changed }.not_to raise_error
  end

  it "requires the typed authorization argument" do
    workflow = claimed_workflow

    expect do
      workflow.execute_authorized_prepared_step!(Object.new)
    end.to raise_error(ArgumentError, /PreparedStepExecutionAuthorization/)
    expect do
      workflow.release_prepared_step_execution!(Object.new)
    end.to raise_error(ArgumentError, /PreparedStepExecutionAuthorization/)
    expect(workflow).to be_prepared_persisted_step
  end

  it "does not copy or serialize process-local execution authority" do
    workflow = claimed_workflow
    authorization = workflow.authorize_prepared_step_execution!

    expect { authorization.dup }.to raise_error(TypeError, /cannot be copied/)
    expect { authorization.clone }.to raise_error(TypeError, /cannot be copied/)
    expect { Marshal.dump(authorization) }.to raise_error(TypeError, /cannot be serialized/)
    expect { Psych.dump(authorization) }.to raise_error(TypeError, /cannot be serialized/)
    expect { JSON.generate(authorization) }.to raise_error(TypeError, /cannot be serialized/)
  end

  it "does not transfer active authority across a process fork" do
    skip "fork is unavailable" unless Process.respond_to?(:fork)

    workflow = claimed_workflow
    authorization = workflow.authorize_prepared_step_execution!
    reader, writer = IO.pipe
    child = fork do
      reader.close
      outcome = begin
        workflow.execute_authorized_prepared_step!(authorization)
        "executed"
      rescue StandardError => e
        "#{e.class}:#{e.message}"
      end
      writer.write(outcome)
      writer.close
      exit! 0
    end
    writer.close
    outcome = reader.read
    Process.wait(child)

    expect(outcome).to include("Smith::WorkflowError")
    expect(outcome).to include("no longer active")
    expect(workflow.execute_authorized_prepared_step!(authorization)).to be_succeeded
  ensure
    reader&.close unless reader&.closed?
    writer&.close unless writer&.closed?
  end

  it "executes the exact agent binding captured by the authorization" do
    original = Class.new(Smith::Agent)
    replacement = Class.new(Smith::Agent) do
      def self.model_configured? = raise("replacement binding ran")
    end
    Smith::Agent::Registry.register(:pinned_agent, original)
    agent_workflow = Class.new(Smith::Workflow) do
      definition_digest Digest::SHA256.hexdigest("pinned-agent")
      idempotency_mode :strict
      initial_state :idle
      state :done
      transition(:finish, from: :idle, to: :done) { execute :pinned_agent }
    end
    workflow = claimed_workflow(agent_workflow, "#{key}:pinned-agent")
    authorization = workflow.authorize_prepared_step_execution!
    Smith::Agent::Registry.delete(:pinned_agent)
    Smith::Agent::Registry.register(:pinned_agent, replacement)

    expect(workflow.execute_authorized_prepared_step!(authorization)).to be_succeeded
    expect(workflow).to be_done
  end

  it "exposes captured bindings before execution and closes them afterward" do
    agent = Class.new(Smith::Agent) { model "test-model" }
    Smith::Agent::Registry.register(:scoped_binding_agent, agent)
    agent_workflow = Class.new(Smith::Workflow) do
      definition_digest Digest::SHA256.hexdigest("scoped-agent-binding")
      idempotency_mode :strict
      initial_state :idle
      state :done
      transition(:finish, from: :idle, to: :done) { execute :scoped_binding_agent }
    end
    workflow = claimed_workflow(agent_workflow, "#{key}:scoped-agent-binding")
    allow(workflow).to receive(:invoke_agent).and_return("done")
    authorization = workflow.authorize_prepared_step_execution!

    binding = authorization.fetch_agent!(
      :scoped_binding_agent,
      workflow_class: agent_workflow,
      transition_name: :finish,
      role: :agent
    )
    expect(binding).to equal(agent)
    captured = []
    expect(authorization.each_agent_binding { |name, klass| captured << [name, klass] }).to equal(authorization)
    expect(captured).to eq([["scoped_binding_agent", agent]])
    expect(workflow.execute_authorized_prepared_step!(authorization)).to be_succeeded
    expect do
      authorization.fetch_agent!(
        :scoped_binding_agent,
        workflow_class: agent_workflow,
        transition_name: :finish,
        role: :agent
      )
    end.to raise_error(Smith::WorkflowError, /outside its binding access scope/)
    expect do
      authorization.each_agent_binding { nil }
    end.to raise_error(Smith::WorkflowError, /outside its binding access scope/)
  end

  it "does not return a deferred captured-binding enumerator" do
    workflow = claimed_workflow
    authorization = workflow.authorize_prepared_step_execution!

    expect do
      authorization.each_agent_binding
    end.to raise_error(ArgumentError, /block is required/)
  ensure
    workflow&.release_prepared_step_execution!(authorization) if authorization
  end

  it "enumerates heterogeneous fanout bindings from the captured authorization" do
    first = Class.new(Smith::Agent)
    second = Class.new(Smith::Agent)
    Smith::Agent::Registry.register(:captured_first, first)
    Smith::Agent::Registry.register(:captured_second, second)
    fanout_workflow = Class.new(Smith::Workflow) do
      definition_digest Digest::SHA256.hexdigest("captured-fanout-bindings")
      idempotency_mode :strict
      initial_state :idle
      state :done
      transition :review, from: :idle, to: :done do
        fan_out branches: { first: :captured_first, second: :captured_second }
      end
    end
    workflow = claimed_workflow(fanout_workflow, "#{key}:captured-fanout")
    authorization = workflow.authorize_prepared_step_execution!
    captured = []

    authorization.each_agent_binding { |name, klass| captured << [name, klass] }

    expect(captured).to eq(
      [
        ["captured_first", first],
        ["captured_second", second]
      ]
    )
  ensure
    workflow&.release_prepared_step_execution!(authorization) if authorization
    Smith::Agent::Registry.delete(:captured_first)
    Smith::Agent::Registry.delete(:captured_second)
  end

  it "passes a root-resolved captured binding into prepared parallel branches" do
    agent = Class.new(Smith::Agent) { model "test-model" }
    Smith::Agent::Registry.register(:prepared_parallel_agent, agent)
    parallel_workflow = Class.new(Smith::Workflow) do
      definition_digest Digest::SHA256.hexdigest("prepared-parallel-binding")
      idempotency_mode :strict
      initial_state :idle
      state :done
      transition :finish, from: :idle, to: :done do
        execute :prepared_parallel_agent, parallel: true, count: 3
      end
    end
    workflow = claimed_workflow(parallel_workflow, "#{key}:prepared-parallel-binding")
    allow(workflow).to receive(:invoke_agent).and_return("done")

    result = workflow.execute_prepared_step!

    expect(result).to include(transition: :finish, to: :done)
    outputs = workflow.to_state.fetch(:last_output).map { _1.fetch(:output) }
    expect(outputs).to eq(%w[done done done])
  end

  it "rejects nested workflow definition drift before child work" do
    child_executions = 0
    child = Class.new(Smith::Workflow) do
      initial_state :start
      state :done
      transition(:answer, from: :start, to: :done) { compute { child_executions += 1 } }
    end
    parent = Class.new(Smith::Workflow) do
      definition_digest Digest::SHA256.hexdigest("nested-authorization")
      idempotency_mode :strict
      initial_state :start
      state :done
      state :failed
      transition :child, from: :start, to: :done do
        workflow child
        on_failure :fail
      end
    end
    workflow = claimed_workflow(parent, "#{key}:nested-drift")
    authorization = workflow.authorize_prepared_step_execution!
    child.transition(:answer, from: :start, to: :done) { compute { child_executions += 100 } }

    result = workflow.execute_authorized_prepared_step!(authorization)

    expect(result).to be_failed
    expect(result.error.message).to include("nested workflow definition changed")
    expect(child_executions).to eq(0)
  end

  it "authorizes nested workflows with mutable topology identifiers" do
    transition_name = [:answer]
    child_executions = 0
    child = Class.new(Smith::Workflow) do
      initial_state :start
      state :done
      transition(transition_name, from: :start, to: :done) { compute { child_executions += 1 } }
    end
    parent = Class.new(Smith::Workflow) do
      definition_digest Digest::SHA256.hexdigest("nested-mutable-identifier")
      idempotency_mode :strict
      initial_state :start
      state :done
      transition(:child, from: :start, to: :done) { workflow child }
    end
    workflow = claimed_workflow(parent, "#{key}:nested-mutable-identifier")

    authorization = workflow.authorize_prepared_step_execution!

    expect(authorization).to be_a(described_class)
    expect(workflow.release_prepared_step_execution!(authorization)).to equal(workflow)
    expect(child_executions).to eq(0)
  end

  it "revalidates a nested workflow after its constructor returns" do
    child_executions = 0
    child = Class.new(Smith::Workflow) do
      initial_state :start
      state :done
      transition(:answer, from: :start, to: :done) { compute { child_executions += 1 } }
    end
    original_new = child.method(:new)
    child.define_singleton_method(:new) do |**arguments|
      instance = original_new.call(**arguments)
      transition(:answer, from: :start, to: :done) { compute { child_executions += 100 } }
      instance
    end
    parent = Class.new(Smith::Workflow) do
      definition_digest Digest::SHA256.hexdigest("nested-constructor-authorization")
      idempotency_mode :strict
      initial_state :start
      state :done
      state :failed
      transition :child, from: :start, to: :done do
        workflow child
        on_failure :fail
      end
    end
    workflow = claimed_workflow(parent, "#{key}:nested-constructor-drift")
    authorization = workflow.authorize_prepared_step_execution!

    result = workflow.execute_authorized_prepared_step!(authorization)

    expect(result).to be_failed
    expect(result.error.message).to include("nested workflow definition changed")
    expect(child_executions).to eq(0)
  end

  it "turns an unsupported provider result into a typed failure before advancing state" do
    mutable_output = Struct.new(:value).new("unsupported")
    agent = Class.new(Smith::Agent) { model "test-model" }
    Smith::Agent::Registry.register(:invalid_result_agent, agent)
    invalid_result_class = Class.new(Smith::Workflow) do
      definition_digest Digest::SHA256.hexdigest("invalid-execution-result")
      idempotency_mode :strict
      initial_state :idle
      state :done
      state :failed
      transition :finish, from: :idle, to: :done do
        execute :invalid_result_agent
        on_failure :fail
      end
      def handle_step_failure(*) = raise("subclass collision")
    end
    workflow = claimed_workflow(invalid_result_class, "#{key}:invalid-result")
    allow(workflow).to receive(:invoke_agent).and_return(mutable_output)
    authorization = workflow.authorize_prepared_step_execution!

    result = workflow.execute_authorized_prepared_step!(authorization)

    expect(result).to be_failed
    expect(result.error).to be_a(Smith::WorkflowError)
    expect(result.error.message).to include("unsupported mutable value")
    expect(workflow.state).to eq(:failed)
    expect(workflow).not_to be_done
  end

  it "does not retain a captured success when session append fails" do
    agent = Class.new(Smith::Agent) { model "test-model" }
    Smith::Agent::Registry.register(:frozen_session_agent, agent)
    frozen_session_class = Class.new(Smith::Workflow) do
      definition_digest Digest::SHA256.hexdigest("frozen-session-result")
      idempotency_mode :strict
      initial_state :idle
      state :done
      state :failed
      transition :finish, from: :idle, to: :done do
        execute :frozen_session_agent
        on_failure :fail
      end
    end
    workflow = claimed_workflow(frozen_session_class, "#{key}:frozen-session")
    allow(workflow).to receive(:invoke_agent).and_return("answer")
    workflow.instance_variable_get(:@session_messages).freeze
    authorization = workflow.authorize_prepared_step_execution!

    result = workflow.execute_authorized_prepared_step!(authorization)

    expect(result).to be_failed
    expect(result.error).to be_a(FrozenError)
    expect(workflow.state).to eq(:failed)
    expect(workflow).not_to be_done
  end

  it "rejects a nested constructor that returns another workflow class" do
    replacement_executions = 0
    replacement = Class.new(Smith::Workflow) do
      initial_state :start
      state :done
      transition(:answer, from: :start, to: :done) { compute { replacement_executions += 1 } }
    end
    child = Class.new(Smith::Workflow) do
      initial_state :start
      state :done
      transition :answer, from: :start, to: :done
    end
    child.define_singleton_method(:new) { |**arguments| replacement.new(**arguments) }
    parent = Class.new(Smith::Workflow) do
      definition_digest Digest::SHA256.hexdigest("nested-constructor-class")
      idempotency_mode :strict
      initial_state :start
      state :done
      state :failed
      transition :child, from: :start, to: :done do
        workflow child
        on_failure :fail
      end
    end
    workflow = claimed_workflow(parent, "#{key}:nested-constructor-class")
    authorization = workflow.authorize_prepared_step_execution!

    result = workflow.execute_authorized_prepared_step!(authorization)

    expect(result).to be_failed
    expect(result.error.message).to include("nested workflow constructor returned")
    expect(replacement_executions).to eq(0)
  end

  it "rejects an oversized durable payload before execution" do
    workflow = claimed_workflow
    adapter.store(key, "x" * (Smith::Workflow::SplitStepPersistence::CanonicalPayloadDigest::MAX_BYTES + 1), ttl: nil)

    expect do
      workflow.authorize_prepared_step_execution!
    end.to raise_error(Smith::PersistencePayloadConflict)
    expect(workflow.state).to eq(:idle)
  end

  it "does not transfer active authority to a copied workflow" do
    workflow = claimed_workflow
    authorization = workflow.authorize_prepared_step_execution!
    copy = workflow.dup

    expect do
      copy.execute_authorized_prepared_step!(authorization)
    end.to raise_error(Smith::WorkflowError, /no longer active/)
    expect(workflow.execute_authorized_prepared_step!(authorization).step).to include(transition: :finish)
  end

  it "revalidates the pinned transition immediately before consuming authority" do
    workflow = claimed_workflow
    authorization = workflow.authorize_prepared_step_execution!
    workflow.class.transition(:finish, from: :idle, to: :done) { compute { raise "replacement ran" } }

    expect do
      workflow.execute_authorized_prepared_step!(authorization)
    end.to raise_error(Smith::WorkflowError, /no longer matches/)
    expect(workflow.release_prepared_step_execution!(authorization)).to equal(workflow)
    expect(workflow).to be_prepared_persisted_step
  end

  it "keeps convenience execution independent of subclass method collisions" do
    colliding_class = Class.new(workflow_class) do
      def authorize_prepared_step_execution! = raise("subclass collision")
      def execute_authorized_prepared_step!(_authorization) = raise("subclass collision")
      def capture_split_step_execution_result!(_step) = raise("subclass collision")
      def complete_step(*) = raise("subclass collision")
      def execute_step(*) = raise("subclass collision")
      def prepare_split_step_execution_result(*) = raise("subclass collision")
      def commit_split_step_execution_result!(*) = raise("subclass collision")
    end
    workflow = claimed_workflow(colliding_class, "#{key}:subclass-collision")

    expect(workflow.execute_prepared_step!).to include(transition: :finish, to: :done)
  end

  it "seals inner execution methods only while prepared authority is active" do
    body_calls = 0
    override_calls = 0
    klass = Class.new(Smith::Workflow) do
      definition_digest Digest::SHA256.hexdigest("inner-execution-collision")
      idempotency_mode :strict
      initial_state :idle
      state :done
      transition(:finish, from: :idle, to: :done) { compute { body_calls += 1 } }

      define_method(:run_with_retry_policy) do |_transition|
        override_calls += 1
        :substituted
      end
      private :run_with_retry_policy
    end

    expect(klass.new.run!.state).to eq(:done)
    expect([body_calls, override_calls]).to eq([0, 1])

    workflow = claimed_workflow(klass, "#{key}:inner-execution-collision")
    result = workflow.execute_prepared_step!

    expect(result).to include(transition: :finish, to: :done)
    expect([body_calls, override_calls]).to eq([1, 1])
  end

  it "extends the prepared execution membrane through nested workflows" do
    body_calls = 0
    override_calls = 0
    child = Class.new(Smith::Workflow) do
      initial_state :idle
      state :done
      transition(:finish, from: :idle, to: :done) { compute { body_calls += 1 } }

      define_method(:run_with_retry_policy) do |_transition|
        override_calls += 1
        :substituted
      end
      private :run_with_retry_policy
    end
    parent = Class.new(Smith::Workflow) do
      definition_digest Digest::SHA256.hexdigest("nested-execution-membrane")
      idempotency_mode :strict
      initial_state :idle
      state :done
      transition(:finish, from: :idle, to: :done) { workflow child }
    end

    expect(child.new.run!.state).to eq(:done)
    expect([body_calls, override_calls]).to eq([0, 1])

    workflow = claimed_workflow(parent, "#{key}:nested-execution-membrane")
    expect(workflow.execute_prepared_step!).to include(transition: :finish, to: :done)
    expect([body_calls, override_calls]).to eq([1, 1])
  end

  it "closes the prepared execution membrane on retained nested workflows" do
    retained_child = nil
    body_calls = 0
    override_calls = 0
    child = Class.new(Smith::Workflow) do
      initial_state :idle
      state :done
      transition(:finish, from: :idle, to: :done) { compute { body_calls += 1 } }

      define_method(:run_with_retry_policy) do |_transition|
        override_calls += 1
        :substituted
      end
      private :run_with_retry_policy
    end
    original_new = child.method(:new)
    child.define_singleton_method(:new) do |**arguments|
      retained_child = original_new.call(**arguments)
    end
    parent = Class.new(Smith::Workflow) do
      definition_digest Digest::SHA256.hexdigest("nested-execution-scope")
      idempotency_mode :strict
      initial_state :idle
      state :done
      transition(:finish, from: :idle, to: :done) { workflow child }
    end
    workflow = claimed_workflow(parent, "#{key}:nested-execution-scope")

    expect(workflow.execute_prepared_step!).to include(transition: :finish, to: :done)
    expect([body_calls, override_calls]).to eq([1, 0])

    transition = child.transition_at(0)
    expect(retained_child.send(:run_with_retry_policy, transition)).to eq(:substituted)
    expect([body_calls, override_calls]).to eq([1, 1])
  end

  it "rejects a dispatch claim for another prepared step" do
    first = claimed_workflow(workflow_class, "#{key}:constructor:first")
    second = claimed_workflow(workflow_class, "#{key}:constructor:second")
    second_authorization = second.authorize_prepared_step_execution!

    expect do
      described_class.new(
        prepared_step: first.prepared_persisted_step,
        dispatch_claim: second_authorization.dispatch_claim,
        execution_bindings: execution_bindings(first)
      )
    end.to raise_error(ArgumentError, /dispatch claim must belong/)
  end
end
