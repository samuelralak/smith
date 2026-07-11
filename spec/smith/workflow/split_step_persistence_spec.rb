# frozen_string_literal: true

RSpec.describe "Smith::Workflow split-step persistence" do
  let(:adapter) { Smith::PersistenceAdapters::Memory.new }
  let(:key) { "workflow:split-step" }
  let(:workflow_class) do
    Class.new(Smith::Workflow) do
      idempotency_mode :strict
      initial_state :idle
      state :done

      transition :finish, from: :idle, to: :done do
        compute { |step| step.write_context(:executed, true) }
      end
    end
  end

  it "prepares, executes, and checkpoints exactly one strict transition" do
    workflow = workflow_class.new

    expect(workflow.prepare_persisted_step!(key, adapter: adapter)).to eq(:finish)
    expect(workflow).to be_prepared_persisted_step

    prepared = JSON.parse(adapter.fetch(key))
    expect(prepared.fetch("step_in_progress")).to be(true)
    expect(prepared.fetch("persistence_version")).to eq(1)
    expect(prepared.fetch("state")).to eq("idle")
    step = workflow.execute_prepared_step!
    expect(step).to include(transition: :finish, from: :idle, to: :done)
    expect(workflow.to_state.fetch(:step_in_progress)).to be(true)
    expect(workflow).not_to be_prepared_persisted_step
    expect(workflow.to_state.fetch(:context)).to include(executed: true)
    expect { workflow.run! }.to raise_error(Smith::WorkflowError, /split-step/)

    workflow.persist!(key, adapter: adapter)
    expect { workflow.run! }.to raise_error(Smith::WorkflowError, /split-step/)
    workflow.complete_persisted_step!
    checkpoint = JSON.parse(adapter.fetch(key))
    expect(checkpoint.fetch("step_in_progress")).to be(false)
    expect(checkpoint.fetch("persistence_version")).to eq(2)
    expect(checkpoint.fetch("state")).to eq("done")
  end

  it "fails closed when a host restores between preparation and acceptance" do
    workflow_class.new.prepare_persisted_step!(key, adapter: adapter)

    expect do
      workflow_class.restore(key, adapter: adapter)
    end.to raise_error(Smith::StepInProgressOnRestore)
  end

  it "fails closed when serialized after execution but before committed completion" do
    workflow = workflow_class.new
    workflow.prepare_persisted_step!(key, adapter: adapter)
    workflow.execute_prepared_step!

    expect do
      workflow_class.from_state(workflow.to_state)
    end.to raise_error(Smith::StepInProgressOnRestore)

    workflow.persist!(key, adapter: adapter)
    expect do
      workflow_class.from_state(workflow.to_state)
    end.to raise_error(Smith::StepInProgressOnRestore)
  end

  it "re-verifies durable preparation immediately before execution" do
    workflow = workflow_class.new
    workflow.prepare_persisted_step!(key, adapter: adapter)
    adapter.delete(key)

    expect do
      workflow.execute_prepared_step!
    end.to raise_error(Smith::WorkflowError, /no longer available/)
    expect(workflow).to be_prepared_persisted_step
    expect(workflow.state).to eq(:idle)
  end

  it "detaches prepared execution state from external mutable aliases" do
    context = { input: "original" }
    observed = nil
    detached_class = Class.new(Smith::Workflow) do
      idempotency_mode :strict
      initial_state :idle
      state :done

      transition :finish, from: :idle, to: :done do
        compute do |step|
          observed = step.read_context(:input)
          step.write_context(:executed, true)
        end
      end
    end
    workflow = detached_class.new(context: context)
    workflow.prepare_persisted_step!(key, adapter: adapter)
    context[:input] = "changed-after-prepare"

    workflow.execute_prepared_step!

    expect(observed).to eq("original")
    expect(workflow.state).to eq(:done)
  end

  it "does not expose prepared execution state through serialization" do
    observed = nil
    detached_class = Class.new(Smith::Workflow) do
      attr_writer :after_split_step_verification

      idempotency_mode :strict
      initial_state :idle
      state :done

      transition :finish, from: :idle, to: :done do
        compute { |step| observed = step.read_context(:input) }
      end

      private

      def verify_split_step_preparation_available!
        super
        @after_split_step_verification.call
      end
    end
    workflow = detached_class.new(context: { input: "prepared" })
    workflow.prepare_persisted_step!(key, adapter: adapter)
    serialized_context = workflow.to_state.fetch(:context)
    workflow.after_split_step_verification = lambda do
      serialized_context[:input] = "mutated-after-verification"
    end

    workflow.execute_prepared_step!

    expect(observed).to eq("prepared")
    expect(workflow.to_state.fetch(:context).fetch(:input)).to eq("prepared")
  end

  it "does not expose mutable session state while a boundary is active" do
    workflow = workflow_class.new
    workflow.prepare_persisted_step!(key, adapter: adapter)

    workflow.session_messages << { role: :user, content: "unprepared mutation" }

    expect(workflow.to_state.fetch(:session_messages)).to eq([])
  end

  it "pins non-expiring persistence through the checkpoint write" do
    original_ttl = Smith.config.persistence_ttl
    workflow = workflow_class.new
    workflow.prepare_persisted_step!(key, adapter: adapter)
    workflow.execute_prepared_step!
    Smith.config.persistence_ttl = 0.02

    workflow.persist!(key, adapter: adapter)
    sleep 0.03

    expect(adapter.fetch(key)).not_to be_nil
    workflow.complete_persisted_step!
  ensure
    Smith.config.persistence_ttl = original_ttl
  end

  it "requires versioned, non-expiring persistence" do
    unversioned = Class.new do
      def store(_key, _payload); end
      def fetch(_key); end
      def delete(_key); end
    end.new
    versioned_without_ttl = Class.new do
      def store_versioned(_key, _payload, expected_version:); end
      def fetch(_key); end
      def delete(_key); end
    end.new
    expiring_class = Class.new(workflow_class) { persistence_ttl 0.02 }

    expect do
      workflow_class.new.prepare_persisted_step!(key, adapter: unversioned)
    end.to raise_error(Smith::WorkflowError, /requires an adapter with store_versioned/)
    expect do
      workflow_class.new.prepare_persisted_step!(key, adapter: versioned_without_ttl)
    end.to raise_error(Smith::WorkflowError, /requires store_versioned to accept ttl:/)
    expect do
      expiring_class.new.prepare_persisted_step!(key, adapter: adapter)
    end.to raise_error(Smith::WorkflowError, /requires non-expiring/)
  end

  it "rejects serializers that remove the strict preparation marker" do
    unsafe_class = Class.new(workflow_class) do
      def to_state = super.merge(step_in_progress: false)
    end
    workflow = unsafe_class.new

    expect do
      workflow.prepare_persisted_step!(key, adapter: adapter)
    end.to raise_error(Smith::WorkflowError, /invalid step_in_progress marker/)
    expect(adapter.fetch(key)).to be_nil
    expect { workflow.advance! }.to raise_error(Smith::WorkflowError, /split-step/)
  end

  it "owns checkpoint marker serialization independently of custom state" do
    unsafe_class = Class.new(workflow_class) do
      def to_state
        state = super
        done? ? state.merge(step_in_progress: true) : state
      end
    end
    workflow = unsafe_class.new
    workflow.prepare_persisted_step!(key, adapter: adapter)
    workflow.execute_prepared_step!

    workflow.persist!(key, adapter: adapter)

    expect(workflow.to_state.fetch(:step_in_progress)).to be(true)
    expect(JSON.parse(adapter.fetch(key)).fetch("step_in_progress")).to be(false)

    workflow.complete_persisted_step!
    expect(workflow.instance_variable_get(:@step_in_progress)).to be(false)
  end

  it "pins a mutable persistence key to an immutable value" do
    mutable_key = String.new("workflow:mutable")
    workflow = workflow_class.new
    workflow.prepare_persisted_step!(mutable_key, adapter: adapter)
    mutable_key.replace("workflow:changed")

    workflow.execute_prepared_step!
    workflow.persist!(adapter: adapter)
    workflow.complete_persisted_step!

    expect(adapter.fetch("workflow:mutable")).not_to be_nil
    expect(adapter.fetch("workflow:changed")).to be_nil
    expect(workflow.to_state.fetch(:persistence_key)).to eq("workflow:mutable")
  end

  it "does not replace the pinned key with an equal mutable checkpoint key" do
    workflow = workflow_class.new
    workflow.prepare_persisted_step!(key, adapter: adapter)
    workflow.execute_prepared_step!
    checkpoint_key = String.new(key)
    workflow.persist!(checkpoint_key, adapter: adapter)
    checkpoint_key.replace("workflow:changed")

    workflow.complete_persisted_step!

    expect(workflow.to_state.fetch(:persistence_key)).to eq(key)
    expect(adapter.fetch("workflow:changed")).to be_nil
  end

  it "preserves a routed transition until its prepared execution" do
    routed_class = Class.new(Smith::Workflow) do
      idempotency_mode :strict
      initial_state :idle
      state :reviewing
      state :done

      transition :draft, from: :idle, to: :reviewing do
        on_success :publish
      end
      transition :publish, from: :reviewing, to: :done
    end
    workflow = routed_class.new

    workflow.prepare_persisted_step!(key, adapter: adapter)
    workflow.execute_prepared_step!
    workflow.persist!(key, adapter: adapter)
    workflow.complete_persisted_step!

    expect(workflow.prepare_persisted_step!(key, adapter: adapter)).to eq(:publish)
  end

  it "retains the uncertainty marker when execution exits abnormally" do
    fatal_error = Class.new(ScriptError)
    unsafe_class = Class.new(Smith::Workflow) do
      idempotency_mode :strict
      initial_state :idle
      state :done

      transition :finish, from: :idle, to: :done do
        compute { raise fatal_error, "interrupted" }
      end
    end
    workflow = unsafe_class.new

    workflow.prepare_persisted_step!(key, adapter: adapter)

    expect { workflow.execute_prepared_step! }.to raise_error(fatal_error, "interrupted")
    expect(workflow).not_to be_prepared_persisted_step
    expect do
      workflow.execute_prepared_step!
    end.to raise_error(Smith::WorkflowError, /no persisted step is prepared/)
    expect(JSON.parse(adapter.fetch(key)).fetch("step_in_progress")).to be(true)
  end

  it "blocks reentrant public execution from the prepared transition" do
    workflow = nil
    reentrant_class = Class.new(Smith::Workflow) do
      idempotency_mode :strict
      initial_state :idle
      state :done

      transition :finish, from: :idle, to: :done do
        compute { workflow.advance! }
      end
    end
    workflow = reentrant_class.new
    workflow.prepare_persisted_step!(key, adapter: adapter)

    expect do
      workflow.execute_prepared_step!
    end.to raise_error(Smith::WorkflowError, /execute_prepared_step/)
    expect(JSON.parse(adapter.fetch(key)).fetch("step_in_progress")).to be(true)
  end

  it "blocks concurrent public execution while the prepared transition runs" do
    entered = Queue.new
    release = Queue.new
    concurrent_class = Class.new(Smith::Workflow) do
      idempotency_mode :strict
      initial_state :idle
      state :done

      transition :finish, from: :idle, to: :done do
        compute do
          entered << true
          release.pop
        end
      end
    end
    workflow = concurrent_class.new
    workflow.prepare_persisted_step!(key, adapter: adapter)
    execution = Thread.new { workflow.execute_prepared_step! }
    entered.pop

    expect { workflow.advance! }.to raise_error(Smith::WorkflowError, /execute_prepared_step/)

    release << true
    expect(execution.value).to include(transition: :finish, to: :done)
  end

  it "blocks preparation while ordinary execution is in progress" do
    entered = Queue.new
    release = Queue.new
    ordinary_class = Class.new(Smith::Workflow) do
      idempotency_mode :strict
      initial_state :idle
      state :done

      transition :finish, from: :idle, to: :done do
        compute do
          entered << true
          release.pop
        end
      end
    end
    workflow = ordinary_class.new
    execution = Thread.new { workflow.advance! }
    entered.pop

    expect do
      workflow.prepare_persisted_step!(key, adapter: adapter)
    end.to raise_error(Smith::WorkflowError, /boundary is already active/)

    release << true
    expect(execution.value).to include(transition: :finish, to: :done)
  end

  it "blocks ordinary execution for the entire preparation path" do
    entered = Queue.new
    release = Queue.new
    workflow = workflow_class.new
    allow(workflow).to receive(:normalize_split_step_persistence_key).and_wrap_original do |original, value|
      entered << true
      release.pop
      original.call(value)
    end
    preparation = Thread.new { workflow.prepare_persisted_step!(key, adapter: adapter) }
    entered.pop

    expect { workflow.advance! }.to raise_error(Smith::WorkflowError, /execute_prepared_step/)
    expect do
      workflow_class.from_state(workflow.to_state)
    end.to raise_error(Smith::StepInProgressOnRestore)

    release << true
    expect(preparation.value).to eq(:finish)
    expect(workflow).to be_prepared_persisted_step
    expect(workflow.state).to eq(:idle)
  end

  it "allows only one concurrent prepared execution claimant" do
    entered = Queue.new
    release = Queue.new
    concurrent_class = Class.new(Smith::Workflow) do
      idempotency_mode :strict
      initial_state :idle
      state :done

      transition :finish, from: :idle, to: :done do
        compute do
          entered << true
          release.pop
        end
      end
    end
    workflow = concurrent_class.new
    workflow.prepare_persisted_step!(key, adapter: adapter)
    winner = Thread.new { workflow.execute_prepared_step! }
    entered.pop
    loser = Thread.new { workflow.execute_prepared_step! }
    loser.report_on_exception = false

    expect { loser.value }.to raise_error(Smith::WorkflowError, /no persisted step is prepared/)

    release << true
    expect(winner.value).to include(transition: :finish, to: :done)
  end

  it "allows only one preparation confirmer" do
    entered = Queue.new
    release = Queue.new
    allow(adapter).to receive(:transaction_open?).and_return(true, false)
    workflow = workflow_class.new
    workflow.prepare_persisted_step!(key, adapter: adapter)
    allow(adapter).to receive(:fetch).and_wrap_original do |original, *args|
      entered << true
      release.pop
      original.call(*args)
    end
    winner = Thread.new { workflow.confirm_prepared_step! }
    entered.pop
    loser = Thread.new { workflow.confirm_prepared_step! }
    loser.report_on_exception = false

    expect { loser.value }.to raise_error(Smith::WorkflowError, /no uncommitted.*awaiting confirmation/)
    expect do
      workflow.persist!(key, adapter: adapter)
    end.to raise_error(Smith::WorkflowError, /cannot be checkpointed/)

    release << true
    expect(winner.value).to equal(workflow)
    expect(workflow).to be_prepared_persisted_step
  end

  it "revokes execution when preparation is not durably accepted" do
    workflow = workflow_class.new
    allow(adapter).to receive(:store_versioned).and_raise(
      Smith::PersistenceVersionConflict.new(key: key, expected: 0, actual: 1)
    )

    expect do
      workflow.prepare_persisted_step!(key, adapter: adapter)
    end.to raise_error(Smith::PersistenceVersionConflict)
    expect(workflow).not_to be_prepared_persisted_step
    expect(workflow.to_state.fetch(:step_in_progress)).to be(false)
    expect do
      workflow.execute_prepared_step!
    end.to raise_error(Smith::WorkflowError, /no persisted step is prepared/)
  end

  it "fails closed when preparation persistence commits and then raises" do
    workflow = workflow_class.new
    allow(adapter).to receive(:store_versioned).and_wrap_original do |original, *args, **kwargs|
      original.call(*args, **kwargs)
      raise IOError, "acknowledgement lost"
    end

    expect do
      workflow.prepare_persisted_step!(key, adapter: adapter)
    end.to raise_error(IOError, "acknowledgement lost")
    expect(JSON.parse(adapter.fetch(key)).fetch("step_in_progress")).to be(true)
    expect { workflow.advance! }.to raise_error(Smith::WorkflowError, /split-step/)
    expect do
      workflow.execute_prepared_step!
    end.to raise_error(Smith::WorkflowError, /no persisted step is prepared/)
  end

  it "fails closed when an acknowledged preparation is reported as a version conflict" do
    workflow = workflow_class.new
    allow(adapter).to receive(:store_versioned).and_wrap_original do |original, *args, **kwargs|
      original.call(*args, **kwargs)
      raise Smith::PersistenceVersionConflict.new(key: key, expected: 0, actual: 1)
    end

    expect do
      workflow.prepare_persisted_step!(key, adapter: adapter)
    end.to raise_error(Smith::PersistenceVersionConflict)
    expect(JSON.parse(adapter.fetch(key)).fetch("step_in_progress")).to be(true)
    expect { workflow.advance! }.to raise_error(Smith::WorkflowError, /split-step/)
  end

  it "does not let a rejected concurrent preparation poison the winner" do
    entered = Queue.new
    release = Queue.new
    allow(adapter).to receive(:store_versioned).and_wrap_original do |original, *args, **kwargs|
      entered << true
      release.pop
      original.call(*args, **kwargs)
    end
    workflow = workflow_class.new
    winner = Thread.new { workflow.prepare_persisted_step!(key, adapter: adapter) }
    entered.pop

    expect do
      workflow.persist!(key, adapter: adapter)
    end.to raise_error(Smith::WorkflowError, /cannot be checkpointed/)
    expect do
      workflow.prepare_persisted_step!("workflow:competing", adapter: adapter)
    end.to raise_error(Smith::WorkflowError, /boundary is already active/)

    release << true
    expect(winner.value).to eq(:finish)
    expect(workflow).to be_prepared_persisted_step
    expect(workflow.to_state.fetch(:persistence_key)).to eq(key)
    allow(adapter).to receive(:store_versioned).and_call_original
    workflow.execute_prepared_step!
    workflow.persist!(adapter: adapter)
    workflow.complete_persisted_step!
  end

  it "binds execution to the exact transition object prepared" do
    workflow = workflow_class.new
    workflow.prepare_persisted_step!(key, adapter: adapter)
    workflow_class.transition(:finish, from: :idle, to: :done)

    expect do
      workflow.execute_prepared_step!
    end.to raise_error(Smith::WorkflowError, /no longer matches/)
  end

  it "freezes the prepared transition contract against in-place mutation" do
    workflow = workflow_class.new
    workflow.prepare_persisted_step!(key, adapter: adapter)
    transition = workflow_class.find_transition(:finish)

    expect { transition.on_success(:surprise) }.to raise_error(FrozenError)
    expect(workflow.execute_prepared_step!).to include(transition: :finish, to: :done)
  end

  it "deeply freezes nested prepared transition configuration" do
    retrying_class = Class.new(Smith::Workflow) do
      idempotency_mode :strict
      initial_state :idle
      state :done

      transition :finish, from: :idle, to: :done do
        compute { true }
        retry_on Smith::AgentError, attempts: 2
      end
    end
    workflow = retrying_class.new
    workflow.prepare_persisted_step!(key, adapter: adapter)
    retry_config = retrying_class.find_transition(:finish).retry_config

    expect { retry_config[:attempts] = 9 }.to raise_error(FrozenError)
  end

  it "binds checkpointing to the preparation key and adapter" do
    workflow = workflow_class.new
    other_adapter = Smith::PersistenceAdapters::Memory.new
    workflow.prepare_persisted_step!(key, adapter: adapter)
    workflow.execute_prepared_step!

    expect do
      workflow.persist!("workflow:other", adapter: adapter)
    end.to raise_error(Smith::WorkflowError, /target cannot change/)
    expect do
      workflow.persist!(key, adapter: other_adapter)
    end.to raise_error(Smith::WorkflowError, /target cannot change/)
    expect(workflow.to_state.fetch(:persistence_key)).to eq(key)

    workflow.persist!(adapter: adapter)
    workflow.complete_persisted_step!
  end

  it "preserves subclass advance wrappers while pinning Smith transition resolution" do
    advance_calls = 0
    subclass = Class.new(workflow_class) do
      define_method(:advance!) do
        advance_calls += 1
        super()
      end

      private

      def ensure_split_step_execution_allowed!(_unexpected_argument) = nil
      def resolve_transition = self.class.find_transition(:other)
    end
    subclass.transition(:other, from: :idle, to: :done)
    workflow = subclass.new
    workflow.prepare_persisted_step!(key, adapter: adapter)

    step = workflow.execute_prepared_step!

    expect(step).to include(transition: :finish, to: :done)
    expect(advance_calls).to eq(1)
    expect(workflow.to_state.fetch(:context)).to include(executed: true)
  end

  it "fails closed when a subclass replaces rather than wraps advance" do
    subclass = Class.new(workflow_class) do
      def advance! = { transition: :hijacked }
    end
    workflow = subclass.new
    workflow.prepare_persisted_step!(key, adapter: adapter)

    expect do
      workflow.execute_prepared_step!
    end.to raise_error(Smith::WorkflowError, /did not return the claimed transition/)
    expect(JSON.parse(adapter.fetch(key)).fetch("step_in_progress")).to be(true)
  end

  it "keeps ordinary runs compatible with a subclass private-method collision" do
    subclass = Class.new(workflow_class) do
      private

      def ensure_split_step_execution_allowed!(_unexpected_argument) = nil
    end

    expect(subclass.new.run!).to be_done
  end

  it "rejects execution and checkpoint bypasses while a step is prepared" do
    workflow = workflow_class.new
    workflow.prepare_persisted_step!(key, adapter: adapter)

    expect { workflow.advance! }.to raise_error(Smith::WorkflowError, /execute_prepared_step/)
    expect { workflow.run! }.to raise_error(Smith::WorkflowError, /split-step/)
    expect { workflow.persist!(key, adapter: adapter) }.to raise_error(Smith::WorkflowError, /checkpointed/)
    expect do
      workflow.advance_persisted!(key, adapter: adapter)
    end.to raise_error(Smith::WorkflowError, /boundary is already active/)
    expect do
      workflow.run_persisted!(key, adapter: adapter)
    end.to raise_error(Smith::WorkflowError, /boundary is already active/)
    expect do
      workflow.clear_persisted!(key, adapter: adapter)
    end.to raise_error(Smith::WorkflowError, /boundary is already active/)
    expect(workflow).not_to respond_to(:clear_split_step_boundary!)
    expect(JSON.parse(adapter.fetch(key)).fetch("persistence_version")).to eq(1)
  end

  it "routes an unresolved prepared transition through normal workflow failure handling" do
    failing_class = Class.new(Smith::Workflow) do
      idempotency_mode :strict
      initial_state :idle
      state :reviewing
      state :failed

      transition :draft, from: :idle, to: :reviewing do
        on_success :missing
      end
    end
    workflow = failing_class.new

    workflow.prepare_persisted_step!(key, adapter: adapter)
    workflow.execute_prepared_step!
    workflow.persist!(key, adapter: adapter)
    workflow.complete_persisted_step!

    expect(workflow.prepare_persisted_step!(key, adapter: adapter)).to eq(:missing)
    step = workflow.execute_prepared_step!

    expect(step).to include(transition: :missing, from: :reviewing, to: :failed)
    expect(step.fetch(:error)).to be_a(Smith::UnresolvedTransitionError)
  end

  it "accepts a declared handled failure route for checkpointing" do
    failing_class = Class.new(Smith::Workflow) do
      idempotency_mode :strict
      initial_state :idle
      state :done
      state :failed

      transition :finish, from: :idle, to: :done do
        compute { raise Smith::WorkflowError, "expected failure" }
        on_failure :fail
      end
    end
    workflow = failing_class.new
    workflow.prepare_persisted_step!(key, adapter: adapter)

    step = workflow.execute_prepared_step!
    workflow.persist!(key, adapter: adapter)
    workflow.complete_persisted_step!

    expect(step.fetch(:error)).to be_a(Smith::WorkflowError)
    expect(workflow).to be_failed
    expect(JSON.parse(adapter.fetch(key)).fetch("state")).to eq("failed")
  end

  it "requires strict idempotency and an existing preparation" do
    lax_class = Class.new(Smith::Workflow) do
      initial_state :idle
      state :done
      transition :finish, from: :idle, to: :done
    end

    expect do
      lax_class.new.prepare_persisted_step!(key, adapter: adapter)
    end.to raise_error(Smith::WorkflowError, /requires idempotency_mode :strict/)
    expect do
      workflow_class.new.execute_prepared_step!
    end.to raise_error(Smith::WorkflowError, /no persisted step is prepared/)
  end

  it "does not copy active split-step execution authority" do
    original = workflow_class.new
    original.prepare_persisted_step!(key, adapter: adapter)
    copy = original.dup

    expect do
      copy.execute_prepared_step!
    end.to raise_error(Smith::WorkflowError, /no persisted step is prepared/)
    expect do
      workflow_class.from_state(copy.to_state)
    end.to raise_error(Smith::StepInProgressOnRestore)
    expect(original.execute_prepared_step!).to include(transition: :finish, to: :done)
  end

  it "rejects duplicate preparation without another persistence write" do
    workflow = workflow_class.new
    workflow.prepare_persisted_step!(key, adapter: adapter)

    expect do
      workflow.prepare_persisted_step!(key, adapter: adapter)
    end.to raise_error(Smith::WorkflowError, /boundary is already active/)
    expect(JSON.parse(adapter.fetch(key)).fetch("persistence_version")).to eq(1)
  end

  it "does not persist or execute a terminal workflow" do
    terminal = workflow_class.new
    terminal.prepare_persisted_step!(key, adapter: adapter)
    terminal.execute_prepared_step!
    expect do
      terminal.prepare_persisted_step!(key, adapter: adapter)
    end.to raise_error(Smith::WorkflowError, /boundary is already active/)
    terminal.persist!(key, adapter: adapter)
    terminal.complete_persisted_step!

    expect(terminal.prepare_persisted_step!(key, adapter: adapter)).to be_nil
    expect(JSON.parse(adapter.fetch(key)).fetch("persistence_version")).to eq(2)
  end

  it "participates in the same Active Record transaction as a host record", :ar, :commit do
    active_record_adapter = Smith::PersistenceAdapters::ActiveRecordStore.new(
      model: SmithWorkflowStateRecord
    )
    rolled_back_key = "workflow:split-step:rolled-back"
    rolled_back = workflow_class.new

    ActiveRecord::Base.transaction(requires_new: true) do
      rolled_back.prepare_persisted_step!(rolled_back_key, adapter: active_record_adapter)
      TransactionalPeerRecord.create!(workflow_key: rolled_back_key, event_name: "step.started")
      raise ActiveRecord::Rollback
    end

    expect(SmithWorkflowStateRecord).not_to exist(key: rolled_back_key)
    expect(TransactionalPeerRecord).not_to exist(workflow_key: rolled_back_key)
    expect do
      rolled_back.confirm_prepared_step!
    end.to raise_error(Smith::WorkflowError, /not committed/)
    expect do
      rolled_back.execute_prepared_step!
    end.to raise_error(Smith::WorkflowError, /no persisted step is prepared/)

    committed_key = "workflow:split-step:committed"
    committed = workflow_class.new
    ActiveRecord::Base.transaction(requires_new: true) do
      committed.prepare_persisted_step!(committed_key, adapter: active_record_adapter)
      TransactionalPeerRecord.create!(workflow_key: committed_key, event_name: "step.started")
    end
    committed.confirm_prepared_step!

    expect(SmithWorkflowStateRecord).to exist(key: committed_key)
    expect(TransactionalPeerRecord).to exist(workflow_key: committed_key)
    expect(committed).to be_prepared_persisted_step
  end

  it "cannot confirm another workflow object's identical preparation", :ar, :commit do
    active_record_adapter = Smith::PersistenceAdapters::ActiveRecordStore.new(
      model: SmithWorkflowStateRecord
    )
    created_at = "2026-07-11T00:00:00Z"
    rolled_back = workflow_class.new(created_at: created_at)
    committed = workflow_class.new(created_at: created_at)

    ActiveRecord::Base.transaction(requires_new: true) do
      rolled_back.prepare_persisted_step!(key, adapter: active_record_adapter)
      raise ActiveRecord::Rollback
    end
    ActiveRecord::Base.transaction(requires_new: true) do
      committed.prepare_persisted_step!(key, adapter: active_record_adapter)
    end

    expect do
      rolled_back.confirm_prepared_step!
    end.to raise_error(Smith::WorkflowError, /not committed/)

    committed.confirm_prepared_step!
    expect(committed.execute_prepared_step!).to include(transition: :finish, to: :done)
  end

  it "keeps a rolled-back post-step checkpoint guarded", :ar, :commit do
    active_record_adapter = Smith::PersistenceAdapters::ActiveRecordStore.new(
      model: SmithWorkflowStateRecord
    )
    workflow = workflow_class.new
    workflow.prepare_persisted_step!(key, adapter: active_record_adapter)
    workflow.execute_prepared_step!

    ActiveRecord::Base.transaction(requires_new: true) do
      workflow.persist!(key, adapter: active_record_adapter)
      TransactionalPeerRecord.create!(workflow_key: key, event_name: "step.completed")
      raise ActiveRecord::Rollback
    end

    expect { workflow.run! }.to raise_error(Smith::WorkflowError, /split-step/)
    expect do
      workflow.complete_persisted_step!
    end.to raise_error(Smith::WorkflowError, /not committed/)
    expect do
      workflow_class.restore(key, adapter: active_record_adapter)
    end.to raise_error(Smith::StepInProgressOnRestore)
  end

  it "refuses checkpoint completion before the transaction commits", :ar, :commit do
    active_record_adapter = Smith::PersistenceAdapters::ActiveRecordStore.new(
      model: SmithWorkflowStateRecord
    )
    workflow = workflow_class.new
    workflow.prepare_persisted_step!(key, adapter: active_record_adapter)
    workflow.execute_prepared_step!

    ActiveRecord::Base.transaction(requires_new: true) do
      workflow.persist!(key, adapter: active_record_adapter)
      expect do
        workflow.complete_persisted_step!
      end.to raise_error(Smith::WorkflowError, /transaction is still open/)
    end

    workflow.complete_persisted_step!
    expect(workflow.run!).to be_done
  end

  it "keeps an accepted step guarded until a failed checkpoint is retried" do
    workflow = workflow_class.new
    workflow.prepare_persisted_step!(key, adapter: adapter)
    workflow.execute_prepared_step!
    allow(adapter).to receive(:store_versioned).and_raise(
      Smith::PersistenceIOError.new(operation: :store_versioned, cause: IOError.new("offline"))
    )

    expect do
      workflow.persist!(key, adapter: adapter)
    end.to raise_error(Smith::PersistenceIOError)
    expect { workflow.run! }.to raise_error(Smith::WorkflowError, /split-step/)

    allow(adapter).to receive(:store_versioned).and_call_original
    workflow.persist!(key, adapter: adapter)
    workflow.complete_persisted_step!

    expect(workflow.run!).to be_done
  end

  it "allows only one concurrent post-step checkpoint claimant" do
    entered = Queue.new
    release = Queue.new
    workflow = workflow_class.new
    workflow.prepare_persisted_step!(key, adapter: adapter)
    workflow.execute_prepared_step!
    allow(adapter).to receive(:store_versioned).and_wrap_original do |original, *args, **kwargs|
      entered << true
      release.pop
      original.call(*args, **kwargs)
    end
    winner = Thread.new { workflow.persist!(key, adapter: adapter) }
    entered.pop
    loser = Thread.new { workflow.persist!(key, adapter: adapter) }
    loser.report_on_exception = false

    expect { loser.value }.to raise_error(Smith::WorkflowError, /cannot be checkpointed/)
    expect do
      workflow_class.from_state(workflow.to_state)
    end.to raise_error(Smith::StepInProgressOnRestore)
    expect do
      workflow.complete_persisted_step!
    end.to raise_error(Smith::WorkflowError, /no persisted.*awaiting completion/)

    release << true
    expect(winner.value).to equal(workflow)
    workflow.complete_persisted_step!
    expect(workflow.run!).to be_done
  end

  it "verifies an ambiguously acknowledged checkpoint without replaying its write" do
    workflow = workflow_class.new
    workflow.prepare_persisted_step!(key, adapter: adapter)
    workflow.execute_prepared_step!
    allow(adapter).to receive(:store_versioned).and_wrap_original do |original, *args, **kwargs|
      original.call(*args, **kwargs)
      raise IOError, "acknowledgement lost"
    end

    expect do
      workflow.persist!(key, adapter: adapter)
    end.to raise_error(IOError, "acknowledgement lost")

    workflow.complete_persisted_step!

    expect(workflow.to_state.fetch(:persistence_version)).to eq(2)
    expect(workflow.run!).to be_done
  end

  it "retains prior checkpoint witnesses across a stateful retry conflict" do
    serialization_count = 0
    changing_class = Class.new(workflow_class) do
      define_method(:to_state) do
        serialization_count += 1 if done?
        super().merge(serialization_count: serialization_count)
      end
    end
    workflow = changing_class.new
    workflow.prepare_persisted_step!(key, adapter: adapter)
    workflow.execute_prepared_step!
    allow(adapter).to receive(:store_versioned).and_wrap_original do |original, *args, **kwargs|
      original.call(*args, **kwargs)
      raise IOError, "acknowledgement lost"
    end
    expect do
      workflow.persist!(key, adapter: adapter)
    end.to raise_error(IOError, "acknowledgement lost")

    allow(adapter).to receive(:store_versioned).and_call_original
    expect do
      workflow.persist!(key, adapter: adapter)
    end.to raise_error(Smith::PersistenceVersionConflict)

    workflow.complete_persisted_step!

    expect(workflow.to_state.fetch(:persistence_version)).to eq(2)
    expect(workflow.run!).to be_done
  end

  it "captures the exact payload serialized by each persistence write" do
    serialization_count = 0
    changing_class = Class.new(workflow_class) do
      define_method(:to_state) do
        serialization_count += 1 if done?
        super().merge(serialization_count: serialization_count)
      end
    end
    workflow = changing_class.new

    workflow.prepare_persisted_step!(key, adapter: adapter)
    workflow.execute_prepared_step!
    workflow.persist!(key, adapter: adapter)
    workflow.complete_persisted_step!

    expect(serialization_count).to eq(1)
    expect(workflow.run!).to be_done
  end

  it "allows only one checkpoint completer" do
    entered = Queue.new
    release = Queue.new
    workflow = workflow_class.new
    workflow.prepare_persisted_step!(key, adapter: adapter)
    workflow.execute_prepared_step!
    workflow.persist!(key, adapter: adapter)
    allow(adapter).to receive(:fetch).and_wrap_original do |original, *args|
      entered << true
      release.pop
      original.call(*args)
    end
    winner = Thread.new { workflow.complete_persisted_step! }
    entered.pop
    loser = Thread.new { workflow.complete_persisted_step! }
    loser.report_on_exception = false

    expect { loser.value }.to raise_error(Smith::WorkflowError, /no persisted.*awaiting completion/)
    expect do
      workflow.persist!(key, adapter: adapter)
    end.to raise_error(Smith::WorkflowError, /cannot be checkpointed/)

    release << true
    expect(winner.value).to equal(workflow)
    expect(workflow.run!).to be_done
  end
end
