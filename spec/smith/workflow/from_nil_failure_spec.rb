# frozen_string_literal: true

require "json"
require "active_support"
require "active_support/cache"

# A step declared `from: nil` runs from whichever state routes to it. Its
# failure keeps that declared origin, nil, as its step result, its
# StepFailed event and its trace do, and is stored, restored and routed by
# `on_failure` as any other step's.
RSpec.describe "Smith::Workflow failure in a from: nil step" do
  let(:workflow_class) { require_const("Smith::Workflow") }
  let(:adapter) { Smith::PersistenceAdapters::Memory.new }

  # An in-memory client with the calls RedisStore makes.
  let(:redis_client) do
    Class.new do
      def initialize = @values = {}
      def get(key) = @values[key]
      def set(key, value, **) = @values.store(key, value)
      def del(*keys) = keys.count { |key| @values.delete(key) }
      def watch(_key) = yield
      def unwatch = nil
      def without_reconnect = yield

      def multi
        yield self
        ["OK"]
      end
    end.new
  end

  let(:adapters) do
    {
      memory: Smith::PersistenceAdapters::Memory.new,
      active_record: Smith::PersistenceAdapters::ActiveRecordStore.new(model: SmithWorkflowStateRecord),
      redis: Smith::PersistenceAdapters::RedisStore.new(redis: redis_client),
      cache_store: Smith::PersistenceAdapters::CacheStore.new(store: ActiveSupport::Cache::MemoryStore.new),
      rails_cache: Smith::PersistenceAdapters::RailsCache.new(store: ActiveSupport::Cache::MemoryStore.new)
    }
  end

  before { SmithWorkflowStateRecord.delete_all }

  # draft routes to the shared check, declared from: nil, which fails and
  # takes `route`, itself from: nil.
  def shared_check(name, mode: :lax, route: :recover, &extra)
    with_stubbed_class(name, workflow_class) do
      idempotency_mode mode
      initial_state :idle
      state :failed

      transition :draft, from: :idle, to: :drafted do
        compute(routes: %i[check]) { |step| step.route_to(:check) }
      end

      transition :check, from: nil, to: :checked do
        compute { |_step| raise Smith::DeterministicStepFailure, "check failed" }
        on_failure route
      end

      transition :recover, from: nil, to: :recovered do
        compute { |step| step.write_context(:recovered, true) }
      end

      class_eval(&extra) if extra
    end
  end

  # One step, restored from the store first, as a host takes each step.
  def advance_restored(klass, key, store)
    klass.restore(key, adapter: store).advance_persisted!(key, adapter: store)
  end

  def advance_until_terminal(klass, key, store)
    loop do
      run = klass.restore(key, adapter: store)
      return run if run.terminal?

      run.advance_persisted!(key, adapter: store)
    end
  end

  def stored_failure(store, key) = JSON.parse(store.fetch(key)).fetch("last_failed_step")

  %i[lax strict].each do |mode|
    context "in #{mode} mode" do
      it "is stored, restored and routed by on_failure in every store adapter" do
        klass = shared_check("SpecFromNilRouted#{mode.capitalize}Workflow", mode:)

        adapters.each do |name, store|
          key = "from-nil-routed-#{mode}-#{name}"
          klass.new.persist!(key, adapter: store)
          2.times { advance_restored(klass, key, store) }

          expect(stored_failure(store, key)).to include("transition" => "check", "from" => nil, "to" => "checked")
          failed = klass.restore(key, adapter: store)
          expect([failed.state, failed.pending_transition_name]).to eq(%i[drafted recover]), name.to_s

          finished = advance_until_terminal(klass, key, store).run_persisted!(key, adapter: store)
          expect([finished.state, finished.context[:recovered]]).to eq([:recovered, true]), name.to_s
        end
        expect(klass.new.run!.state).to eq(:recovered)
      end

      it "ends a run failed, and the restored run reads the failure as the run that made it did" do
        klass = shared_check("SpecFromNilFailed#{mode.capitalize}Workflow", mode:, route: :fail)

        adapters.each do |name, store|
          key = "from-nil-failed-#{mode}-#{name}"
          fresh = klass.new.run_persisted!(key, adapter: store)
          restored = klass.restore(key, adapter: store).run_persisted!(key, adapter: store)

          expect([fresh.state, restored.state]).to eq(%i[failed failed]), name.to_s
          expect(restored.last_error).to be_a(Smith::DeterministicStepFailure)
          expect(restored.last_error.message).to eq("check failed")
          expect(restored.failure_detail.except(:error)).to eq(transition: :check, from: nil, to: :checked)
          expect(restored.failure_detail.except(:error)).to eq(fresh.failure_detail.except(:error))
        end
      end
    end
  end

  describe "the restore paths" do
    # A run stored once its from: nil step failed and before its on_failure ran.
    def stored_after_failure(klass, key)
      klass.new.persist!(key, adapter:)
      2.times { advance_restored(klass, key, adapter) }
    end

    it "continues through the class-level run_persisted! and restore_or_initialize" do
      klass = shared_check("SpecFromNilClassLevelWorkflow")
      stored_after_failure(klass, "class-level")
      stored_after_failure(klass, "or-initialize")

      expect(klass.restorable_billing_state?(key: "class-level", adapter:)).to be(false)
      expect(klass.run_persisted!(key: "class-level", adapter:, clear: false).state).to eq(:recovered)
      restored = klass.restore_or_initialize(key: "or-initialize", adapter:)
      expect([restored.state, restored.pending_transition_name]).to eq(%i[drafted recover])
    end

    it "continues after a durable retry's last attempt fails, its wait expired through a restore" do
      stub_const("SpecFromNilBusy", Class.new(StandardError))
      allow_any_instance_of(workflow_class).to receive(:sleep).and_raise("a durable retry slept")
      klass = shared_check("SpecFromNilDurableWorkflow") do
        transition :check, from: nil, to: :checked do
          compute { |_step| raise SpecFromNilBusy, "busy" }
          retry_on SpecFromNilBusy, attempts: 2, backoff: 30, durable: true
          on_failure :recover
        end
      end

      klass.new.run_persisted!("durable", adapter:)
      wait = klass.restore("durable", adapter:).awaiting
      expect(klass.expire_wait!("durable", token: wait.token, now: wait.deadline_at, adapter:)).to eq(:expired)
      klass.restore("durable", adapter:).advance_persisted!("durable", adapter:)

      expect(stored_failure(adapter, "durable")).to include("transition" => "check", "from" => nil)
      expect(klass.restore("durable", adapter:).run_persisted!("durable", adapter:).state).to eq(:recovered)
    end

    it "goes through the renames of a later version, its origin kept nil" do
      stored_after_failure(shared_check("SpecFromNilBeforeRenameWorkflow"), "renamed")
      renamed = with_stubbed_class("SpecFromNilAfterRenameWorkflow", workflow_class) do
        initial_state :idle
        renamed_transition :recover, to: :repair

        transition :draft, from: :idle, to: :drafted do
          compute(routes: %i[check]) { |step| step.route_to(:check) }
        end

        transition :check, from: nil, to: :checked do
          compute { |_step| raise Smith::DeterministicStepFailure, "check failed" }
          on_failure :repair
        end

        transition :repair, from: nil, to: :recovered do
          compute { |step| step.write_context(:recovered, true) }
        end
      end

      restored = renamed.restore("renamed", adapter:)

      expect(restored.pending_transition_name).to eq(:repair)
      expect(restored.instance_variable_get(:@last_failed_step)).to include(transition: :check, from: nil)
      expect(restored.run_persisted!("renamed", adapter:).state).to eq(:recovered)
    end
  end

  describe "a stored failure record" do
    let(:klass) { shared_check("SpecFromNilRecordWorkflow", route: :fail) }

    # As Smith 0.13.0 stored the failure of a from: nil step.
    let(:record) do
      {
        "transition" => "check", "from" => nil, "to" => "checked",
        "error_class" => "Smith::DeterministicStepFailure", "error_family" => "deterministic_step_failure",
        "error_message" => "check failed", "error_retryable" => nil, "error_retry_forbidden" => false,
        "error_kind" => nil, "error_details" => nil,
        "error_cause_class" => nil, "error_cause_family" => nil, "error_cause_message" => nil
      }
    end

    def payload(record, state: "failed")
      JSON.parse(JSON.generate(klass.new.to_state)).merge("state" => state, "last_failed_step" => record)
    end

    it "restores as 0.13.0 stored it, and the restored run reads it" do
      result = klass.from_state(payload(record)).send(:build_run_result, [])

      expect(result.last_error).to be_a(Smith::DeterministicStepFailure)
      expect(result.failure_detail.except(:error)).to eq(transition: :check, from: nil, to: :checked)
    end

    it "still fails closed on an origin that is not a state name, or a record without one" do
      invalid = {
        123 => /from state must be text/, "" => /from state is invalid/, ("x" * 257) => /from state is invalid/
      }
      invalid.each do |from, message|
        expect { klass.from_state(payload(record.merge("from" => from))) }
          .to raise_error(Smith::PersistedFailureInvalid, message)
      end
      expect { klass.from_state(payload(record.except("from"))) }
        .to raise_error(Smith::PersistedFailureInvalid, /incomplete/)
    end

    it "still requires its transition and its to state" do
      expect { klass.from_state(payload(record.merge("transition" => nil))) }
        .to raise_error(Smith::PersistedFailureInvalid, /transition must be text/)
      expect { klass.from_state(payload(record.merge("to" => nil))) }
        .to raise_error(Smith::PersistedFailureInvalid, /to state must be text/)
    end
  end
end
