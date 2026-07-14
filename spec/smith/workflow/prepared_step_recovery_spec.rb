# frozen_string_literal: true

RSpec.describe "Smith::Workflow prepared-step recovery" do
  let(:adapter) { Smith::PersistenceAdapters::Memory.new }
  let(:key) { "workflow:prepared-recovery" }
  let(:definition_digest) { Digest::SHA256.hexdigest("spec-recoverable-workflow-v1") }
  let(:workflow_class) do
    digest = definition_digest
    stub_const("SpecRecoverableWorkflow", Class.new(Smith::Workflow) do
      definition_digest digest
      idempotency_mode :strict
      initial_state :idle
      state :done

      transition :finish, from: :idle, to: :done do
        compute { |step| step.write_context(:executed, true) }
      end
    end)
  end

  def prepare(workflow = workflow_class.new)
    workflow.prepare_persisted_step!(key, adapter: adapter)
    workflow.prepared_persisted_step
  end

  def recovery_for(descriptor)
    Smith::Workflow::PreparedStepRecovery.not_started(descriptor)
  end

  it "reconstructs an exact committed preparation and completes one transition" do
    descriptor = prepare
    serialized = JSON.generate(descriptor.to_h)
    restored_descriptor = Smith::Workflow::PreparedStep.deserialize(serialized)

    workflow = workflow_class.recover_prepared_step(recovery_for(restored_descriptor), adapter: adapter)
    workflow.claim_prepared_step_dispatch!
    step = workflow.execute_prepared_step!
    workflow.persist!(key, adapter: adapter)
    workflow.complete_persisted_step!

    expect(step).to include(transition: :finish, from: :idle, to: :done)
    expect(workflow.to_state).to include(
      state: :done,
      step_in_progress: false,
      persistence_version: 2,
      definition_digest: definition_digest
    )
  end

  it "keeps ordinary strict restore fail-closed" do
    prepare

    expect do
      workflow_class.restore(key, adapter: adapter)
    end.to raise_error(Smith::StepInProgressOnRestore)
  end

  it "requires an explicit immutable not-started recovery decision" do
    descriptor = prepare
    recovery = recovery_for(descriptor)

    expect(recovery).to have_attributes(
      prepared_step: descriptor,
      dispatch_claim: nil,
      execution_status: :not_started
    )
    expect(recovery).to be_frozen
    expect(recovery.attributes).to be_frozen
    expect do
      Smith::Workflow::PreparedStepRecovery.new(prepared_step: descriptor, execution_status: :unknown)
    end.to raise_error(Dry::Struct::Error)
    expect do
      workflow_class.recover_prepared_step(descriptor, adapter: adapter)
    end.to raise_error(ArgumentError, /PreparedStepRecovery/)
  end

  it "strictly deserializes persisted descriptors" do
    descriptor = prepare
    serialized = JSON.generate(descriptor.to_h)

    expect(Smith::Workflow::PreparedStep.deserialize(serialized).to_h).to eq(descriptor.to_h)
    expect(Smith::Workflow::PreparedStep.deserialize(JSON.parse(serialized)).to_h).to eq(descriptor.to_h)
    expect do
      Smith::Workflow::PreparedStep.deserialize(JSON.parse(serialized).merge("unexpected" => true))
    end.to raise_error(ArgumentError, /unknown attributes/)
    expect do
      Smith::Workflow::PreparedStep.deserialize("[]")
    end.to raise_error(ArgumentError, /JSON must contain an object/)
    expect do
      Smith::Workflow::PreparedStep.deserialize(format("{%s}", " " * 4096))
    end.to raise_error(ArgumentError, /bounded JSON object/)
    expect do
      Smith::Workflow::PreparedStep.deserialize(descriptor.to_h.merge(token: "x" * 4096))
    end.to raise_error(ArgumentError, /Hash exceeds maximum bytes/)
  end

  it "rejects every mismatched descriptor identity field" do
    descriptor = prepare
    replacements = {
      token: SecureRandom.uuid,
      transition: "other",
      from: "other",
      persistence_key: "workflow:other",
      persistence_version: 2,
      step_number: 2,
      preparation_digest: "f" * 64,
      definition_digest: "e" * 64
    }

    replacements.each do |attribute, value|
      candidate = Smith::Workflow::PreparedStep.new(descriptor.to_h.merge(attribute => value))
      expect do
        workflow_class.recover_prepared_step(recovery_for(candidate), adapter: adapter)
      end.to raise_error(Smith::WorkflowError), "expected recovery to reject #{attribute}"
    end
  end

  it "rejects payload mutation even when scalar identity remains unchanged" do
    descriptor = prepare
    document = JSON.parse(adapter.fetch(key))
    document.fetch("context")["tampered"] = true
    adapter.store(key, JSON.generate(document), ttl: nil)

    expect do
      workflow_class.recover_prepared_step(recovery_for(descriptor), adapter: adapter)
    end.to raise_error(Smith::WorkflowError, /digest does not match/)
  end

  it "rejects oversized recovery payloads before parsing" do
    descriptor = prepare
    oversized = "{#{" " * Smith::Workflow::SplitStepPersistence::CanonicalPayloadDigest::MAX_BYTES}}"
    adapter.store(key, oversized, ttl: nil)

    expect do
      workflow_class.recover_prepared_step(recovery_for(descriptor), adapter: adapter)
    end.to raise_error(Smith::WorkflowError, /exceeds maximum bytes/)
  end

  it "requires the same named workflow class, schema, and definition digest" do
    descriptor = prepare
    other_digest = definition_digest
    other_class = stub_const("SpecOtherRecoverableWorkflow", Class.new(Smith::Workflow) do
      definition_digest other_digest
      idempotency_mode :strict
      initial_state :idle
      state :done
      transition(:finish, from: :idle, to: :done) { compute { nil } }
    end)

    expect do
      other_class.recover_prepared_step(recovery_for(descriptor), adapter: adapter)
    end.to raise_error(Smith::WorkflowError, /current workflow definition/)

    workflow_class.persistence_schema_version(2)
    expect do
      workflow_class.recover_prepared_step(recovery_for(descriptor), adapter: adapter)
    end.to raise_error(Smith::WorkflowError, /current workflow definition/)

    workflow_class.persistence_schema_version(1)
    workflow_class.definition_digest("f" * 64)
    expect do
      workflow_class.recover_prepared_step(recovery_for(descriptor), adapter: adapter)
    end.to raise_error(Smith::WorkflowError, /current workflow definition/)
  end

  it "rejects recovery without a durable workflow definition identity" do
    anonymous = Class.new(Smith::Workflow) do
      idempotency_mode :strict
      initial_state :idle
      state :done
      transition :finish, from: :idle, to: :done
    end
    workflow = anonymous.new
    workflow.prepare_persisted_step!(key, adapter: adapter)

    expect do
      anonymous.recover_prepared_step(recovery_for(workflow.prepared_persisted_step), adapter: adapter)
    end.to raise_error(Smith::WorkflowError, /current workflow definition/)
  end

  it "requires the same versioned non-expiring adapter contract" do
    descriptor = prepare
    unversioned = Object.new
    unversioned.define_singleton_method(:store) { |*, **| nil }
    unversioned.define_singleton_method(:fetch) { |_| adapter.fetch(key) }
    unversioned.define_singleton_method(:delete) { |_| nil }

    expect do
      workflow_class.recover_prepared_step(recovery_for(descriptor), adapter: unversioned)
    end.to raise_error(Smith::WorkflowError, /requires an adapter with store_versioned/)

    workflow_class.persistence_ttl(60)
    expect do
      workflow_class.recover_prepared_step(recovery_for(descriptor), adapter: adapter)
    end.to raise_error(Smith::WorkflowError, /non-expiring workflow persistence/)
  end

  it "rejects an incompatible exact-replacement signature before preparation writes" do
    incompatible = Smith::PersistenceAdapters::Memory.new(identity: "incompatible")
    incompatible.define_singleton_method(:replace_exact) { |_key, _payload| nil }

    expect do
      workflow_class.new.prepare_persisted_step!("workflow:incompatible", adapter: incompatible)
    end.to raise_error(Smith::WorkflowError, /replace_exact\(key, payload, expected_payload:, ttl:\)/)
    expect(incompatible.fetch("workflow:incompatible")).to be_nil
  end

  it "rejects an exact-replacement method with extra required keywords before writing" do
    incompatible = Smith::PersistenceAdapters::Memory.new(identity: "extra-keyword")
    incompatible.define_singleton_method(:replace_exact) do |*, expected_payload:, ttl:, tenant:, **|
      [expected_payload, ttl, tenant]
    end

    expect do
      workflow_class.new.prepare_persisted_step!("workflow:extra-keyword", adapter: incompatible)
    end.to raise_error(Smith::WorkflowError, /replace_exact\(key, payload, expected_payload:, ttl:\)/)
    expect(incompatible.fetch("workflow:extra-keyword")).to be_nil
  end

  it "requires committed host recovery authority outside an adapter transaction" do
    descriptor = prepare
    adapter.define_singleton_method(:transaction_open?) { true }

    expect do
      workflow_class.recover_prepared_step(recovery_for(descriptor), adapter: adapter)
    end.to raise_error(Smith::WorkflowError, /outside a transaction/)
  end

  it "re-verifies the exact durable preparation immediately before recovered execution" do
    descriptor = prepare
    workflow = workflow_class.recover_prepared_step(recovery_for(descriptor), adapter: adapter)
    adapter.delete(key)

    expect do
      workflow.claim_prepared_step_dispatch!
    end.to raise_error(Smith::PersistencePayloadConflict)
    expect(workflow).not_to be_prepared_persisted_step
    expect(workflow.state).to eq(:idle)
  end

  it "requires an exact dispatch claim before restart-safe execution" do
    workflow = workflow_class.recover_prepared_step(recovery_for(prepare), adapter: adapter)

    expect do
      workflow.execute_prepared_step!
    end.to raise_error(Smith::WorkflowError, /prepared for execution/)

    workflow.claim_prepared_step_dispatch!
    expect(workflow).to be_prepared_persisted_step
    expect(workflow.execute_prepared_step!).to include(transition: :finish, to: :done)
  end

  it "recovers a committed dispatch claim when the host proves execution did not start" do
    workflow = workflow_class.recover_prepared_step(recovery_for(prepare), adapter: adapter)
    dispatch = workflow.claim_prepared_step_dispatch!
    serialized = JSON.generate(dispatch.to_h)
    restored_dispatch = Smith::Workflow::PreparedStepDispatch.deserialize(serialized)
    recovered = workflow_class.recover_prepared_step(
      Smith::Workflow::PreparedStepRecovery.not_started(restored_dispatch),
      adapter: adapter
    )

    expect(restored_dispatch).to have_attributes(
      prepared_step: workflow.prepared_persisted_step,
      token: dispatch.token,
      dispatch_digest: dispatch.dispatch_digest
    )
    expect(restored_dispatch).to be_frozen
    expect(recovered).to be_prepared_persisted_step
    expect(recovered.execute_prepared_step!).to include(transition: :finish, to: :done)
  end

  it "rejects a mismatched committed dispatch receipt" do
    workflow = workflow_class.recover_prepared_step(recovery_for(prepare), adapter: adapter)
    dispatch = workflow.claim_prepared_step_dispatch!
    mismatched = Smith::Workflow::PreparedStepDispatch.new(
      prepared_step: dispatch.prepared_step,
      token: dispatch.token,
      dispatch_digest: "f" * 64
    )

    expect do
      workflow_class.recover_prepared_step(
        Smith::Workflow::PreparedStepRecovery.not_started(mismatched),
        adapter: adapter
      )
    end.to raise_error(Smith::WorkflowError, /digest does not match/)
  end

  it "rejects workflow-class mutation after recovery and permits only one execution attempt" do
    descriptor = prepare
    workflow = workflow_class.recover_prepared_step(recovery_for(descriptor), adapter: adapter)
    workflow_class.transition(:finish, from: :idle, to: :done) { compute { nil } }

    expect do
      workflow.claim_prepared_step_dispatch!
    end.to raise_error(Smith::WorkflowError, /no longer matches/)

    adapter.delete(key)
    stable_descriptor = prepare(workflow_class.new)
    stable = workflow_class.recover_prepared_step(recovery_for(stable_descriptor), adapter: adapter)
    stable.claim_prepared_step_dispatch!
    stable.execute_prepared_step!
    expect do
      stable.execute_prepared_step!
    end.to raise_error(Smith::WorkflowError, /no persisted step is prepared/)
  end

  it "allows only one exact dispatch claimant across original and recovered objects" do
    entered = Queue.new
    release = Queue.new
    digest = definition_digest
    concurrent_class = stub_const("SpecConcurrentRecoveryWorkflow", Class.new(Smith::Workflow) do
      definition_digest digest
      idempotency_mode :strict
      initial_state :idle
      state :done

      transition :finish, from: :idle, to: :done do
        compute do
          entered << true
          release.pop
        end
      end
    end)
    original = concurrent_class.new
    original.prepare_persisted_step!(key, adapter: adapter)
    recovered = concurrent_class.recover_prepared_step(
      recovery_for(original.prepared_persisted_step),
      adapter: adapter
    )
    results = Queue.new
    workers = [original, recovered].map do |workflow|
      Thread.new do
        workflow.claim_prepared_step_dispatch!
        results << workflow.execute_prepared_step!
      rescue StandardError => e
        results << e
      end
    end

    entered.pop
    rejected = results.pop
    release << true
    workers.each(&:join)
    accepted = results.pop

    expect([rejected, accepted].count { |result| result.is_a?(Hash) }).to eq(1)
    expect([rejected, accepted].count { |result| result.is_a?(Smith::PersistencePayloadConflict) }).to eq(1)
  end

  it "does not let a rejected same-object claimant revoke the active claim" do
    descriptor = prepare
    workflow = workflow_class.recover_prepared_step(recovery_for(descriptor), adapter: adapter)
    entered = Queue.new
    release = Queue.new
    allow(adapter).to receive(:replace_exact).and_wrap_original do |original, *args, **kwargs|
      entered << true
      release.pop
      original.call(*args, **kwargs)
    end
    winner = Thread.new { workflow.claim_prepared_step_dispatch! }
    entered.pop
    loser = Thread.new do
      workflow.claim_prepared_step_dispatch!
    rescue StandardError => e
      e
    end

    rejected = loser.value
    release << true
    accepted = winner.value

    expect(rejected).to be_a(Smith::WorkflowError)
    expect(accepted).to be_a(Smith::Workflow::PreparedStepDispatch)
    expect(workflow).to be_prepared_persisted_step
  end

  it "fails closed when an exact dispatch acknowledgement is ambiguous" do
    descriptor = prepare
    workflow = workflow_class.recover_prepared_step(recovery_for(descriptor), adapter: adapter)
    allow(adapter).to receive(:replace_exact).and_wrap_original do |original, *args, **kwargs|
      original.call(*args, **kwargs)
      raise IOError, "acknowledgement lost"
    end

    expect do
      workflow.claim_prepared_step_dispatch!
    end.to raise_error(IOError, "acknowledgement lost")
    expect(workflow).not_to be_prepared_persisted_step
    expect(JSON.parse(adapter.fetch(key))).to include(
      "step_in_progress" => true,
      "split_step_phase" => "dispatching"
    )
    expect do
      workflow_class.recover_prepared_step(recovery_for(descriptor), adapter: adapter)
    end.to raise_error(Smith::WorkflowError)
  end

  it "rejects definition-digest drift after recovery" do
    workflow = workflow_class.recover_prepared_step(recovery_for(prepare), adapter: adapter)
    workflow_class.definition_digest("f" * 64)

    expect do
      workflow.claim_prepared_step_dispatch!
    end.to raise_error(Smith::WorkflowError, /definition has changed/)
    expect(JSON.parse(adapter.fetch(key))).to include(
      "definition_digest" => definition_digest,
      "split_step_phase" => "prepared"
    )
  end

  it "keeps the descriptor bound to the digest pinned before serialization" do
    original_digest = Digest::SHA256.hexdigest("definition-before-serialization")
    replacement_digest = Digest::SHA256.hexdigest("definition-during-serialization")
    changed_digest = replacement_digest
    changing_class = stub_const("SpecChangingDefinitionWorkflow", Class.new(Smith::Workflow) do
      definition_digest original_digest
      idempotency_mode :strict
      initial_state :idle
      state :done
      transition :finish, from: :idle, to: :done

      define_method(:to_state) do
        self.class.definition_digest(changed_digest)
        super()
      end
    end)
    workflow = changing_class.new
    changing_key = "workflow:changing-definition"

    workflow.prepare_persisted_step!(changing_key, adapter: adapter)

    expect(workflow.prepared_persisted_step.definition_digest).to eq(original_digest)
    expect(JSON.parse(adapter.fetch(changing_key))).to include("definition_digest" => original_digest)
    expect do
      workflow.claim_prepared_step_dispatch!
    end.to raise_error(Smith::WorkflowError, /definition has changed/)
  end

  it "does not convert a prepared legacy boundary into restart-safe execution" do
    legacy_class = stub_const("SpecPinnedLegacyWorkflow", Class.new(Smith::Workflow) do
      idempotency_mode :strict
      initial_state :idle
      state :done
      transition :finish, from: :idle, to: :done
    end)
    legacy = legacy_class.new
    legacy.prepare_persisted_step!("workflow:pinned-legacy", adapter: adapter)
    legacy_class.definition_digest("a" * 64)

    expect do
      legacy.execute_prepared_step!
    end.to raise_error(Smith::WorkflowError, /definition has changed/)
    expect(JSON.parse(adapter.fetch("workflow:pinned-legacy"))).to include("definition_digest" => nil)
  end

  it "confirms a transaction-coordinated dispatch claim before execution" do
    workflow = workflow_class.recover_prepared_step(recovery_for(prepare), adapter: adapter)
    transaction_open = true
    adapter.define_singleton_method(:transaction_open?) { transaction_open }
    adapter.define_singleton_method(:transaction_identity) { "transaction:dispatch" if transaction_open }

    workflow.claim_prepared_step_dispatch!
    expect(workflow).not_to be_prepared_persisted_step
    expect do
      workflow.execute_prepared_step!
    end.to raise_error(Smith::WorkflowError, /prepared for execution/)
    expect do
      workflow.confirm_prepared_step_dispatch!
    end.to raise_error(Smith::WorkflowError, /transaction is still open/)

    transaction_open = false
    workflow.confirm_prepared_step_dispatch!
    expect(workflow).to be_prepared_persisted_step
    expect(workflow.execute_prepared_step!).to include(transition: :finish, to: :done)
  end

  it "does not let a rejected concurrent confirmation revoke the active confirmation" do
    workflow = workflow_class.recover_prepared_step(recovery_for(prepare), adapter: adapter)
    transaction_open = true
    adapter.define_singleton_method(:transaction_open?) { transaction_open }
    adapter.define_singleton_method(:transaction_identity) { "transaction:confirmation" if transaction_open }
    workflow.claim_prepared_step_dispatch!
    transaction_open = false
    entered = Queue.new
    release = Queue.new
    allow(adapter).to receive(:fetch).and_wrap_original do |original, *args|
      entered << true
      release.pop
      original.call(*args)
    end
    winner = Thread.new { workflow.confirm_prepared_step_dispatch! }
    entered.pop
    loser = Thread.new do
      workflow.confirm_prepared_step_dispatch!
    rescue StandardError => e
      e
    end

    rejected = loser.value
    release << true
    accepted = winner.value

    expect(rejected).to be_a(Smith::WorkflowError)
    expect(accepted).to equal(workflow)
    expect(workflow).to be_prepared_persisted_step
  end

  it "restores a transaction-coordinated claim when its exact write rolled back" do
    workflow = workflow_class.recover_prepared_step(recovery_for(prepare), adapter: adapter)
    prepared_payload = adapter.fetch(key)
    transaction_open = true
    adapter.define_singleton_method(:transaction_open?) { transaction_open }
    adapter.define_singleton_method(:transaction_identity) { "transaction:rollback" if transaction_open }

    workflow.claim_prepared_step_dispatch!
    adapter.store(key, prepared_payload, ttl: nil)
    transaction_open = false

    expect do
      workflow.confirm_prepared_step_dispatch!
    end.to raise_error(Smith::WorkflowError, /not committed/)
    workflow.claim_prepared_step_dispatch!
    expect(workflow.execute_prepared_step!).to include(transition: :finish, to: :done)
  end
  it "inherits the immutable workflow definition digest" do
    child = Class.new(workflow_class)

    expect(child.definition_digest).to equal(workflow_class.definition_digest)
    expect(child.definition_digest).to be_frozen
  end
end
