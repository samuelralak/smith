# frozen_string_literal: true

require "spec_helper"
require "json"

RSpec.describe "Smith::Context persist :auto" do
  let(:workflow_class) { require_const("Smith::Workflow") }
  let(:context_class) { require_const("Smith::Context") }

  describe "DSL" do
    it "persist :auto sets persist_mode to :auto" do
      manager = with_stubbed_class("AutoCtxA", context_class) do
        persist :auto
      end
      expect(manager.persist_mode).to eq(:auto)
      expect(manager.persist).to eq([])
      expect(manager.persist_auto_seed).to eq([])
    end

    it "persist :auto, also: [:k] declares an input seed list" do
      manager = with_stubbed_class("AutoCtxB", context_class) do
        persist :auto, also: [:user_message, :ticket_id]
      end
      expect(manager.persist_mode).to eq(:auto)
      expect(manager.persist_auto_seed).to eq([:user_message, :ticket_id])
    end

    it "persist :auto, also: with a single symbol still works" do
      manager = with_stubbed_class("AutoCtxC", context_class) do
        persist :auto, also: :user_message
      end
      expect(manager.persist_auto_seed).to eq([:user_message])
    end

    it "persist :a, :b stays in :explicit mode" do
      manager = with_stubbed_class("AutoCtxD", context_class) do
        persist :a, :b
      end
      expect(manager.persist_mode).to eq(:explicit)
      expect(manager.persist).to eq([:a, :b])
    end

    it "persist(also: [:k]) without :auto raises WorkflowError" do
      expect {
        with_stubbed_class("AutoCtxE", context_class) do
          persist also: [:foo]
        end
      }.to raise_error(Smith::WorkflowError, /:also is only valid alongside :auto/)
    end

    it "persist :auto, :extra (positional) raises WorkflowError" do
      expect {
        with_stubbed_class("AutoCtxF", context_class) do
          persist :auto, :extra
        end
      }.to raise_error(Smith::WorkflowError, /persist :auto must be the sole positional/)
    end
  end

  describe "subclass inheritance" do
    it "explicit-mode child merges parent keys (existing semantics preserved)" do
      parent = with_stubbed_class("AutoParentExplicit", context_class) do
        persist :a, :b
      end
      child = with_stubbed_class("AutoChildExplicit", parent) do
        persist :c
      end
      expect(child.persist).to eq([:a, :b, :c])
      expect(child.persist_mode).to eq(:explicit)
    end

    it "auto-mode child inherits parent's mode and seed" do
      parent = with_stubbed_class("AutoParentMode", context_class) do
        persist :auto, also: [:seed_a]
      end
      child = with_stubbed_class("AutoChildInherit", parent) do
      end
      expect(child.persist_mode).to eq(:auto)
      expect(child.persist_auto_seed).to eq([:seed_a])
    end

    it "child redeclaring :auto replaces seed list (not merge)" do
      parent = with_stubbed_class("AutoParentReplace", context_class) do
        persist :auto, also: [:seed_a]
      end
      child = with_stubbed_class("AutoChildRedeclare", parent) do
        persist :auto, also: [:seed_b]
      end
      expect(child.persist_auto_seed).to eq([:seed_b])
    end

    it "child switching from auto to explicit replaces mode entirely" do
      parent = with_stubbed_class("AutoParentSwitch", context_class) do
        persist :auto, also: [:seed_a]
      end
      child = with_stubbed_class("AutoChildExplicitSwitch", parent) do
        persist :x, :y
      end
      expect(child.persist_mode).to eq(:explicit)
      expect(child.persist).to eq([:x, :y])
    end
  end

  describe "runtime auto-tracking" do
    let(:manager) do
      with_stubbed_class("AutoRuntimeCtx", context_class) do
        persist :auto, also: [:input_a]
      end
    end

    let(:workflow_klass) do
      mgr = manager
      with_stubbed_class("AutoRuntimeWorkflow", workflow_class) do
        context_manager mgr
        initial_state :idle
        state :working
        state :done

        transition :step1, from: :idle, to: :working do
          compute do |step|
            step.write_context(:produced_b, 42)
          end
        end

        transition :step2, from: :working, to: :done do
          compute do |step|
            step.write_context(:produced_c, "hello")
          end
        end
      end
    end

    it "seeds @persisted_keys from also: at construction time" do
      wf = workflow_klass.new(context: { input_a: "in", drop_me: "x" })
      expect(wf.persisted_keys).to include(:input_a)
    end

    it "does NOT auto-track keys supplied via initial context: kwarg" do
      wf = workflow_klass.new(context: { input_a: "in", drop_me: "x" })
      expect(wf.persisted_keys).not_to include(:drop_me)
    end

    it "records keys written via step.write_context after run!" do
      wf = workflow_klass.new(context: { input_a: "in" })
      wf.run!
      expect(wf.persisted_keys).to include(:input_a, :produced_b, :produced_c)
    end

    it "persisted_context slices to recorded keys only" do
      wf = workflow_klass.new(context: { input_a: "in", drop_me: "x" })
      wf.run!
      state = wf.to_state
      expect(state[:context].keys).to contain_exactly(:input_a, :produced_b, :produced_c)
      expect(state[:context]).not_to have_key(:drop_me)
    end

    it "round-trips persisted_keys through to_state/from_state" do
      wf = workflow_klass.new(context: { input_a: "in" })
      wf.run!
      state = wf.to_state
      expect(state[:persisted_keys]).to eq([:input_a, :produced_b, :produced_c])

      restored = workflow_klass.from_state(JSON.parse(JSON.generate(state)))
      expect(restored.persisted_keys).to include(:input_a, :produced_b, :produced_c)
    end

    it "step that raises mid-block records no writes" do
      mgr = manager
      raising_klass = with_stubbed_class("AutoRaisingWorkflow", workflow_class) do
        context_manager mgr
        initial_state :idle
        state :failed

        transition :explode, from: :idle, to: :failed do
          compute do |step|
            step.write_context(:should_not_persist, 1)
            raise "boom"
          end
          on_failure :fail
        end
      end

      wf = raising_klass.new(context: { input_a: "in" })
      wf.run!
      expect(wf.persisted_keys).not_to include(:should_not_persist)
    end
  end

  describe "restore migration from pre-:auto payloads" do
    let(:manager) do
      with_stubbed_class("AutoRestoreCtx", context_class) do
        persist :auto, also: [:input_a]
      end
    end

    let(:workflow_klass) do
      mgr = manager
      with_stubbed_class("AutoRestoreWorkflow", workflow_class) do
        context_manager mgr
        initial_state :idle
        state :done

        transition :finish, from: :idle, to: :done do
          compute { |_step| nil }
        end
      end
    end

    it "seeds @persisted_keys from existing context keys when :persisted_keys is absent" do
      legacy = {
        "class" => "AutoRestoreWorkflow",
        "state" => "idle",
        "context" => { "input_a" => "in", "produced_b" => 42, "produced_c" => "hello" },
        "budget_consumed" => {},
        "step_count" => 0,
        "created_at" => "2026-06-24T00:00:00Z",
        "updated_at" => "2026-06-24T00:00:00Z"
      }
      restored = workflow_klass.from_state(legacy)
      expect(restored.persisted_keys.to_a.map(&:to_sym)).to include(:input_a, :produced_b, :produced_c)
    end
  end

  describe "explicit-mode still works byte-identically" do
    let(:manager) do
      with_stubbed_class("ExplicitCompatCtx", context_class) do
        persist :a, :b
      end
    end

    let(:workflow_klass) do
      mgr = manager
      with_stubbed_class("ExplicitCompatWorkflow", workflow_class) do
        context_manager mgr
        initial_state :idle
      end
    end

    it "persisted_context filters to declared keys, ignoring extras" do
      wf = workflow_klass.new(context: { a: 1, b: 2, c: 3 })
      state = wf.to_state
      expect(state[:context]).to eq(a: 1, b: 2)
    end

    it "to_state now includes :persisted_keys (forward-compat shape)" do
      wf = workflow_klass.new(context: { a: 1, b: 2 })
      expect(wf.to_state).to have_key(:persisted_keys)
    end
  end
end
