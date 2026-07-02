# frozen_string_literal: true

# Pins the idempotency_mode contract: under :strict, run_persisted! /
# advance_persisted! stamp the step_in_progress marker before each
# advance and clear it after. Restoring a payload with the marker still
# set raises Smith::StepInProgressOnRestore because a previous worker
# crashed mid-step (the step's side effects are unknown). Default :lax
# leaves the marker false and never raises.

RSpec.describe "Smith::Workflow step_in_progress idempotency marker" do
  let(:adapter) { Smith::PersistenceAdapters::Memory.new }

  def workflow_class(mode: :lax)
    persistence_mode = mode
    Class.new(Smith::Workflow) do
      persistence_key { |_ctx| "workflow:idempotency-test" }
      idempotency_mode(persistence_mode)
      initial_state :idle
      state :working
      state :done
      transition :start, from: :idle, to: :working
      transition :finish, from: :working, to: :done
    end
  end

  it "defaults idempotency_mode to :lax" do
    klass = Class.new(Smith::Workflow) do
      initial_state :idle
      state :done
      transition :finish, from: :idle, to: :done
    end

    expect(klass.idempotency_mode).to eq(:lax)
  end

  it "to_state carries step_in_progress: false on a fresh workflow" do
    workflow = workflow_class.new
    expect(workflow.to_state[:step_in_progress]).to be(false)
  end

  describe ":lax mode (default)" do
    it "never raises on restore even if the persisted payload marks step_in_progress true" do
      klass = workflow_class(mode: :lax)
      workflow = klass.new
      workflow.instance_variable_set(:@step_in_progress, true)
      workflow.persist!("workflow:idempotency-test", adapter: adapter)

      expect { klass.restore("workflow:idempotency-test", adapter: adapter) }.not_to raise_error
    end

    it "does NOT stamp the marker around advance_persisted!" do
      klass = workflow_class(mode: :lax)
      workflow = klass.new
      workflow.advance_persisted!("workflow:idempotency-test", adapter: adapter)

      payload = JSON.parse(adapter.fetch("workflow:idempotency-test"))
      expect(payload["step_in_progress"]).to be(false)
    end
  end

  describe ":strict mode" do
    it "raises Smith::StepInProgressOnRestore when the restored payload has the marker set" do
      klass = workflow_class(mode: :strict)
      workflow = klass.new
      workflow.instance_variable_set(:@step_in_progress, true)
      workflow.persist!("workflow:idempotency-test", adapter: adapter)

      expect { klass.restore("workflow:idempotency-test", adapter: adapter) }.to raise_error(Smith::StepInProgressOnRestore) do |err|
        expect(err.persistence_key).to eq("workflow:idempotency-test")
      end
    end

    it "does NOT raise on restore when the marker is false (clean step boundary)" do
      klass = workflow_class(mode: :strict)
      workflow = klass.new
      workflow.persist!("workflow:idempotency-test", adapter: adapter)

      expect { klass.restore("workflow:idempotency-test", adapter: adapter) }.not_to raise_error
    end

    it "captures step_in_progress=true in the pre-advance persist (simulates mid-step worker crash)" do
      klass = workflow_class(mode: :strict)
      workflow = klass.new

      # Spy on advance! to inspect the persisted payload at the
      # exact moment the worker would crash mid-step. This is the
      # same boundary a SIGKILL would terminate at: after the
      # pre-advance persist, before clear_step_in_progress! and the
      # post-advance persist.
      captured_payload_at_advance = nil
      original_advance = workflow.method(:advance!)
      allow(workflow).to receive(:advance!) do
        captured_payload_at_advance = JSON.parse(adapter.fetch("workflow:idempotency-test"))
        original_advance.call
      end

      workflow.advance_persisted!("workflow:idempotency-test", adapter: adapter)

      expect(captured_payload_at_advance["step_in_progress"]).to be(true)
    end

    it "marker stays set when a non-StandardError escapes advance!" do
      klass = workflow_class(mode: :strict)
      workflow = klass.new

      # `raise Exception` slips past execute_step's `rescue StandardError`
      # block and advance!'s narrower `rescue UnresolvedTransitionError`,
      # mirroring a worker crash on SystemExit / SignalException.
      allow(workflow).to receive(:advance!).and_raise(Exception.new("simulated crash"))

      expect do
        workflow.advance_persisted!("workflow:idempotency-test", adapter: adapter)
      end.to raise_error(Exception, /simulated crash/)

      payload = JSON.parse(adapter.fetch("workflow:idempotency-test"))
      expect(payload["step_in_progress"]).to be(true)

      expect { klass.restore("workflow:idempotency-test", adapter: adapter) }.to raise_error(Smith::StepInProgressOnRestore)
    end

    it "clears the marker on successful advance" do
      klass = workflow_class(mode: :strict)
      workflow = klass.new
      workflow.advance_persisted!("workflow:idempotency-test", adapter: adapter)

      payload = JSON.parse(adapter.fetch("workflow:idempotency-test"))
      expect(payload["step_in_progress"]).to be(false)
    end

    it "does not poison persisted state when transition budget is exhausted before step work starts" do
      klass = Class.new(Smith::Workflow) do
        persistence_key { |_ctx| "workflow:idempotency-budget-test" }
        idempotency_mode :strict
        max_transitions 0
        initial_state :idle
        state :done
        transition :finish, from: :idle, to: :done
      end

      workflow = klass.new
      workflow.persist!("workflow:idempotency-budget-test", adapter: adapter)

      expect do
        workflow.advance_persisted!("workflow:idempotency-budget-test", adapter: adapter)
      end.to raise_error(Smith::MaxTransitionsExceeded)

      payload = JSON.parse(adapter.fetch("workflow:idempotency-budget-test"))
      expect(payload["step_in_progress"]).to be(false)
      expect { klass.restore("workflow:idempotency-budget-test", adapter: adapter) }.not_to raise_error
    end

    it "does not poison persisted state when advance_persisted fails before step work starts" do
      klass = Class.new(Smith::Workflow) do
        idempotency_mode :strict
        initial_state :idle
        state :middle
        state :other
        state :done

        transition :start, from: :idle, to: :middle do
          on_success :finish
        end

        transition :finish, from: :other, to: :done
      end

      workflow = klass.new
      workflow.advance!
      workflow.persist!("workflow:idempotency-origin-test", adapter: adapter)

      expect do
        workflow.advance_persisted!("workflow:idempotency-origin-test", adapter: adapter)
      end.to raise_error(Smith::WorkflowError, /cannot run from state :middle/)

      payload = JSON.parse(adapter.fetch("workflow:idempotency-origin-test"))
      expect(payload["step_in_progress"]).to be(false)
      expect { klass.restore("workflow:idempotency-origin-test", adapter: adapter) }.not_to raise_error
    end

    it "does not poison persisted state when run_persisted fails before step work starts" do
      klass = Class.new(Smith::Workflow) do
        idempotency_mode :strict
        initial_state :idle
        state :middle
        state :other
        state :done

        transition :start, from: :idle, to: :middle do
          on_success :finish
        end

        transition :finish, from: :other, to: :done
      end

      expect do
        klass.new.run_persisted!("workflow:idempotency-run-origin-test", adapter: adapter)
      end.to raise_error(Smith::WorkflowError, /cannot run from state :middle/)

      payload = JSON.parse(adapter.fetch("workflow:idempotency-run-origin-test"))
      expect(payload["step_in_progress"]).to be(false)
      expect { klass.restore("workflow:idempotency-run-origin-test", adapter: adapter) }.not_to raise_error
    end
  end

  it "treats a pre-marker payload (no step_in_progress key) as false" do
    klass = workflow_class(mode: :strict)
    legacy_payload = {
      class: klass.name, state: :idle, persistence_key: "workflow:idempotency-test",
      context: {}, budget_consumed: {}, step_count: 0,
      created_at: Time.now.utc.iso8601, updated_at: Time.now.utc.iso8601,
      session_messages: [], total_cost: 0.0, total_tokens: 0,
      tool_results: [], outcome: nil, usage_entries: [],
      last_output: nil, last_failed_step: nil,
      persistence_version: 1, schema_version: 1, seed_digest: nil
      # Note: no :step_in_progress key
    }
    adapter.store("workflow:idempotency-test", JSON.generate(legacy_payload))

    expect { klass.restore("workflow:idempotency-test", adapter: adapter) }.not_to raise_error
  end

  it "propagates idempotency_mode through class inheritance" do
    parent = workflow_class(mode: :strict)
    child = Class.new(parent)

    expect(child.idempotency_mode).to eq(:strict)
  end

  describe "DSL validation" do
    it "rejects unknown idempotency_mode values" do
      expect {
        Class.new(Smith::Workflow) do
          idempotency_mode :paranoid
        end
      }.to raise_error(ArgumentError, /must be :strict or :lax/)
    end
  end
end
