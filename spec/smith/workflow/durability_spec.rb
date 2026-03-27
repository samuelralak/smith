# frozen_string_literal: true

require "json"

RSpec.describe "Smith::Workflow durability helpers" do
  let(:workflow_class) { require_const("Smith::Workflow") }
  let(:agent_class) { require_const("Smith::Agent") }
  let(:context_class) { require_const("Smith::Context") }
  let(:workflow_error) { require_const("Smith::WorkflowError") }

  let(:adapter) do
    Class.new do
      attr_reader :writes, :deleted

      def initialize
        @store = {}
        @writes = []
        @deleted = []
      end

      def store(key, payload)
        @writes << [key, JSON.parse(payload)]
        @store[key] = payload
      end

      def fetch(key)
        @store[key]
      end

      def delete(key)
        @deleted << key
        @store.delete(key)
      end
    end.new
  end

  it "restores an existing workflow by key or initializes a new one when no state exists" do
    klass = with_stubbed_class("SpecDurableRestoreWorkflow", workflow_class) do
      initial_state :idle
      state :done

      transition :finish, from: :idle, to: :done
    end

    fresh = klass.restore_or_initialize(key: "missing", context: { topic: "trade" }, adapter:)
    expect(fresh.state).to eq(:idle)
    expect(fresh.to_state[:context]).to eq(topic: "trade")

    persisted = klass.new(context: { topic: "payments" })
    persisted.advance!
    persisted.persist!("existing", adapter:)

    restored = klass.restore_or_initialize(key: "existing", context: { topic: "ignored" }, adapter:)
    expect(restored.state).to eq(:done)
    expect(restored.to_state[:context]).to eq(topic: "payments")
  end

  it "treats the restore lookup key as authoritative over any embedded persistence_key in stored state" do
    klass = with_stubbed_class("SpecRestoreAuthoritativeKeyWorkflow", workflow_class) do
      persistence_key { |ctx| "workflow:#{ctx[:ticket_id]}" }

      initial_state :idle
      state :done

      transition :finish, from: :idle, to: :done
    end

    corrupted = klass.new(context: { ticket_id: "T-1" })
    corrupted.persist!("workflow:T-1", adapter:)

    payload = JSON.parse(adapter.fetch("workflow:T-1"))
    payload["persistence_key"] = "workflow:corrupted"
    adapter.store("workflow:T-1", JSON.generate(payload))

    restored = klass.restore("workflow:T-1", adapter:)

    expect(restored.to_state[:persistence_key]).to eq("workflow:T-1")

    restored.clear_persisted!(adapter:)

    expect(adapter.deleted).to include("workflow:T-1")
    expect(adapter.deleted).not_to include("workflow:corrupted")
  end

  it "checkpoints before execution and after each accepted transition" do
    klass = with_stubbed_class("SpecCheckpointWorkflow", workflow_class) do
      initial_state :idle
      state :mid
      state :done

      transition :first, from: :idle, to: :mid
      transition :second, from: :mid, to: :done
    end

    result = klass.new.run_persisted!("wf:1", adapter:)

    expect(result.state).to eq(:done)
    expect(result.steps.map { |step| step[:transition] }).to eq(%i[first second])
    expect(adapter.writes.length).to eq(3)
    expect(adapter.writes.map { |(_, state)| state["state"] || state[:state] }).to eq(%w[idle mid done])
  end

  it "invokes a per-run step callback after each accepted checkpointed step" do
    klass = with_stubbed_class("SpecOnStepPersistedWorkflow", workflow_class) do
      initial_state :idle
      state :mid
      state :done

      transition :first, from: :idle, to: :mid
      transition :second, from: :mid, to: :done
    end

    seen = []

    result = klass.new.run_persisted!("wf:on-step", adapter:, on_step: ->(step) { seen << step[:transition] })

    expect(result.state).to eq(:done)
    expect(seen).to eq(%i[first second])
    expect(adapter.writes.map { |(_, state)| state["state"] || state[:state] }).to eq(%w[idle mid done])
  end

  it "logs and ignores per-run step callback failures after checkpointing" do
    klass = with_stubbed_class("SpecOnStepFailurePersistedWorkflow", workflow_class) do
      initial_state :idle
      state :done

      transition :finish, from: :idle, to: :done
    end

    logger = instance_double("Logger")
    original_logger = Smith.config.logger
    allow(logger).to receive(:error)
    Smith.configure { |config| config.logger = logger }

    result = klass.new.run_persisted!("wf:on-step-failure", adapter:, on_step: ->(_step) { raise "boom" })

    expect(result.state).to eq(:done)
    expect(adapter.fetch("wf:on-step-failure")).not_to be_nil
    expect(logger).to have_received(:error).with(/Smith::Workflow on_step callback error: boom/)
  ensure
    Smith.configure { |config| config.logger = original_logger }
  end

  it "supports a declarative persistence_key for class-level convenience calls" do
    klass = with_stubbed_class("SpecDerivedKeyWorkflow", workflow_class) do
      persistence_key { |ctx| "workflow:#{ctx[:ticket_id]}" }

      initial_state :idle
      state :done

      transition :finish, from: :idle, to: :done
    end

    result = klass.run_persisted!(context: { ticket_id: "T-1042" }, adapter:, clear: false)

    expect(result.state).to eq(:done)
    expect(adapter.fetch("workflow:T-1042")).not_to be_nil
  end

  it "prefers an explicit key over a workflow-declared persistence_key" do
    klass = with_stubbed_class("SpecExplicitKeyOverrideWorkflow", workflow_class) do
      persistence_key { |ctx| "workflow:#{ctx[:ticket_id]}" }

      initial_state :idle
      state :done

      transition :finish, from: :idle, to: :done
    end

    klass.run_persisted!(key: "workflow:explicit", context: { ticket_id: "ignored" }, adapter:, clear: false)

    expect(adapter.fetch("workflow:explicit")).not_to be_nil
    expect(adapter.fetch("workflow:ignored")).to be_nil
  end

  it "supports declarative persistence_key for instance-level durability helpers" do
    klass = with_stubbed_class("SpecDerivedKeyInstanceWorkflow", workflow_class) do
      persistence_key { |ctx| "workflow:#{ctx[:ticket_id]}" }

      initial_state :idle
      state :done

      transition :finish, from: :idle, to: :done
    end

    workflow = klass.new(context: { ticket_id: "T-2048" })

    workflow.run_persisted!(adapter:, on_step: ->(_step) { nil })

    expect(adapter.fetch("workflow:T-2048")).not_to be_nil
  end

  it "keeps the resolved persistence key stable across restore for instance-level helpers" do
    manager = with_stubbed_class("SpecDerivedKeyPersistedContextManager", context_class) do
      persist :ticket_id
    end

    klass = with_stubbed_class("SpecDerivedKeyRestoredInstanceWorkflow", workflow_class) do
      context_manager manager
      persistence_key { |ctx| "workflow:#{ctx[:ticket_id]}:#{ctx[:nonce]}" }

      initial_state :idle
      state :done

      transition :finish, from: :idle, to: :done
    end

    workflow = klass.new(context: { ticket_id: "T-4096", nonce: "N-7" })
    workflow.persist!(adapter:)

    restored = klass.restore("workflow:T-4096:N-7", adapter:)

    expect(restored.to_state[:context]).to eq(ticket_id: "T-4096")
    expect { restored.persist!(adapter:) }.not_to raise_error
    expect(adapter.writes.last.first).to eq("workflow:T-4096:N-7")

    restored.clear_persisted!(adapter:)

    expect(adapter.deleted).to eq(["workflow:T-4096:N-7"])
    expect(adapter.fetch("workflow:T-4096:N-7")).to be_nil
  end

  it "raises a workflow error when no explicit key is provided and no persistence_key DSL is declared" do
    klass = with_stubbed_class("SpecMissingDerivedKeyWorkflow", workflow_class) do
      initial_state :idle
      state :done

      transition :finish, from: :idle, to: :done
    end

    expect do
      klass.run_persisted!(context: { ticket_id: "missing" }, adapter:)
    end.to raise_error(workflow_error, /persistence key is required/)
  end

  it "raises a workflow error when persistence_key returns a blank value" do
    klass = with_stubbed_class("SpecBlankDerivedKeyWorkflow", workflow_class) do
      persistence_key { |_ctx| "" }
      initial_state :idle
    end

    expect do
      klass.run_persisted!(context: { ticket_id: "blank" }, adapter:)
    end.to raise_error(workflow_error, /persistence_key must return a non-blank key/)
  end

  it "raises a workflow error when persistence_key returns nil" do
    klass = with_stubbed_class("SpecNilDerivedKeyWorkflow", workflow_class) do
      persistence_key { |_ctx| nil }
      initial_state :idle
    end

    expect do
      klass.run_persisted!(context: { ticket_id: "nil" }, adapter:)
    end.to raise_error(workflow_error, /persistence_key must return a non-blank key/)
  end

  it "raises a workflow error when restore is called with a blank explicit key" do
    klass = with_stubbed_class("SpecBlankRestoreKeyWorkflow", workflow_class) do
      initial_state :idle
    end

    expect { klass.restore(nil, adapter:) }.to raise_error(workflow_error, /restore requires a non-blank explicit persistence key/)
    expect { klass.restore("", adapter:) }.to raise_error(workflow_error, /restore requires a non-blank explicit persistence key/)
    expect(adapter.writes).to eq([])
    expect(adapter.deleted).to eq([])
  end

  it "offers a class-level one-liner for restore, checkpointed execution, and successful cleanup" do
    klass = with_stubbed_class("SpecClassRunPersistedWorkflow", workflow_class) do
      initial_state :idle
      state :done

      transition :finish, from: :idle, to: :done
    end

    result = klass.run_persisted!(key: "wf:class-run", context: { topic: "trade" }, adapter:)

    expect(result.state).to eq(:done)
    expect(adapter.deleted).to eq(["wf:class-run"])
    expect(adapter.fetch("wf:class-run")).to be_nil
  end

  it "can preserve terminal state instead of clearing it after the class-level run" do
    klass = with_stubbed_class("SpecClassRunPersistedNoClearWorkflow", workflow_class) do
      initial_state :idle
      state :done

      transition :finish, from: :idle, to: :done
    end

    result = klass.run_persisted!(key: "wf:no-clear", adapter:, clear: false)

    expect(result.state).to eq(:done)
    expect(adapter.deleted).to eq([])
    expect(adapter.fetch("wf:no-clear")).not_to be_nil
  end

  it "can clear failed terminal state when requested through the class-level run" do
    agent = with_stubbed_class("SpecDurabilityFailingAgent", agent_class) do
      register_as :spec_durability_failing_agent
      model "gpt-5-mini"
    end

    chat = Object.new
    chat.define_singleton_method(:add_message) { |_message| nil }
    chat.define_singleton_method(:complete) { raise StandardError, "boom" }

    allow(agent).to receive(:chat).and_return(chat)

    klass = with_stubbed_class("SpecClassRunPersistedClearTerminalWorkflow", workflow_class) do
      initial_state :idle
      state :failed

      transition :explode, from: :idle, to: :failed do
        execute :spec_durability_failing_agent
        on_failure :fail
      end
    end

    result = klass.run_persisted!(key: "wf:clear-terminal", adapter:, clear: :terminal)

    expect(result.failed?).to eq(true)
    expect(adapter.deleted).to eq(["wf:clear-terminal"])
    expect(adapter.fetch("wf:clear-terminal")).to be_nil
  end

  it "clears a terminal workflow with a non-standard terminal state when clear policy is :terminal" do
    klass = with_stubbed_class("SpecClearCustomTerminalWorkflow", workflow_class) do
      initial_state :idle
      state :completed

      transition :finish, from: :idle, to: :completed
    end

    result = klass.run_persisted!(key: "wf:custom-terminal", adapter:, clear: :terminal)

    expect(result.state).to eq(:completed)
    expect(adapter.deleted).to eq(["wf:custom-terminal"])
    expect(adapter.fetch("wf:custom-terminal")).to be_nil
  end

  it "raises a workflow error when the class-level clear policy is invalid" do
    klass = with_stubbed_class("SpecClassRunPersistedInvalidClearWorkflow", workflow_class) do
      initial_state :idle
    end

    expect do
      klass.run_persisted!(key: "wf:bad-clear", adapter:, clear: :always)
    end.to raise_error(workflow_error, /invalid clear policy/)
    expect(adapter.writes).to eq([])
  end

  it "supports single-step checkpointing through advance_persisted!" do
    klass = with_stubbed_class("SpecAdvancePersistedWorkflow", workflow_class) do
      initial_state :idle
      state :mid
      state :done

      transition :first, from: :idle, to: :mid
      transition :second, from: :mid, to: :done
    end

    workflow = klass.new

    step = workflow.advance_persisted!("wf:advance", adapter:)

    expect(step[:transition]).to eq(:first)
    expect(workflow.state).to eq(:mid)
    expect(adapter.writes.length).to eq(2)
    expect(adapter.writes.map { |(_, state)| state["state"] || state[:state] }).to eq(%w[idle mid])
  end

  it "returns immediately without persisting when run_persisted! is called on a terminal workflow" do
    klass = with_stubbed_class("SpecTerminalRunPersistedWorkflow", workflow_class) do
      initial_state :done
    end

    result = klass.new.run_persisted!("wf:terminal-run", adapter:)

    expect(result.state).to eq(:done)
    expect(result.steps).to eq([])
    expect(adapter.writes).to eq([])
  end

  it "returns immediately on a terminal workflow without requiring key resolution" do
    klass = with_stubbed_class("SpecTerminalRunPersistedNoKeyWorkflow", workflow_class) do
      initial_state :done
    end

    workflow = klass.new

    expect { workflow.run_persisted!(adapter:) }.not_to raise_error
    expect(adapter.writes).to eq([])
  end

  it "returns immediately without persisting when advance_persisted! is called on a terminal workflow" do
    klass = with_stubbed_class("SpecTerminalAdvancePersistedWorkflow", workflow_class) do
      initial_state :done
    end

    workflow = klass.new

    expect(workflow.advance_persisted!("wf:terminal", adapter:)).to be_nil
    expect(adapter.writes).to eq([])
  end

  it "exposes persisted cleanup through clear_persisted!" do
    klass = with_stubbed_class("SpecPersistedClearWorkflow", workflow_class) do
      initial_state :idle
    end

    workflow = klass.new
    workflow.persist!("wf:clear", adapter:)
    workflow.clear_persisted!("wf:clear", adapter:)

    expect(adapter.deleted).to eq(["wf:clear"])
    expect(adapter.fetch("wf:clear")).to be_nil
  end

  it "raises a workflow error when durability helpers are used without a configured adapter" do
    klass = with_stubbed_class("SpecMissingAdapterWorkflow", workflow_class) do
      initial_state :idle
    end

    workflow = klass.new

    expect { workflow.persist!("wf:no-adapter", adapter: nil) }.to raise_error(workflow_error, /persistence_adapter/)
    expect { klass.restore("wf:no-adapter", adapter: nil) }.to raise_error(workflow_error, /persistence_adapter/)
  end

  it "exposes state predicates on workflows and run results" do
    agent = with_stubbed_class("SpecDurabilityPredicateAgent", agent_class) do
      register_as :spec_durability_predicate_agent
      model "gpt-5-mini"
    end

    chat = Object.new
    chat.define_singleton_method(:add_message) { |_message| nil }
    chat.define_singleton_method(:complete) { Struct.new(:content).new("done") }

    allow(agent).to receive(:chat).and_return(chat)

    klass = with_stubbed_class("SpecDurabilityPredicateWorkflow", workflow_class) do
      initial_state :idle
      state :done
      state :failed

      transition :finish, from: :idle, to: :done do
        execute :spec_durability_predicate_agent
      end
    end

    workflow = klass.new
    expect(workflow.terminal?).to eq(false)
    expect(workflow.done?).to eq(false)
    expect(workflow.failed?).to eq(false)

    result = workflow.run!

    expect(workflow.terminal?).to eq(true)
    expect(workflow.done?).to eq(true)
    expect(workflow.failed?).to eq(false)
    expect(result.done?).to eq(true)
    expect(result.failed?).to eq(false)
    expect(result.terminal_output).to eq("done")
    expect(result.last_error).to be_nil
  end
end
