# frozen_string_literal: true

require "spec_helper"
require "logger"
require "stringio"

RSpec.describe Smith::Workflow::ExecutionFrame do
  let(:on_clear) { -> { on_clear_log << :called } }
  let(:always_ensure) { -> { always_log << :called } }
  let(:on_clear_log) { [] }
  let(:always_log) { [] }
  let(:logger_io) { StringIO.new }
  let(:logger) { Logger.new(logger_io) }

  describe "decision table" do
    it "(1) claimed=false: skips on_clear and always_ensure" do
      described_class.run(on_clear: on_clear, always_ensure: always_ensure, logger: logger) do |frame|
        frame.mark_claimed!(false)
      end

      expect(on_clear_log).to be_empty
      expect(always_log).to be_empty
    end

    it "(2) claimed=true alone (pre-run early return): on_clear AND always_ensure both fire" do
      described_class.run(on_clear: on_clear, always_ensure: always_ensure, logger: logger) do |frame|
        frame.mark_claimed!(true)
      end

      expect(on_clear_log).to eq([:called])
      expect(always_log).to eq([:called])
    end

    it "(3) claimed=true, result_obtained, not recorded: on_clear skipped, always_ensure fires" do
      described_class.run(on_clear: on_clear, always_ensure: always_ensure, logger: logger) do |frame|
        frame.mark_claimed!(true)
        frame.mark_result_obtained!
      end

      expect(on_clear_log).to be_empty
      expect(always_log).to eq([:called])
    end

    it "(4) claimed=true, recorded, no retry, no finalize: on_clear skipped" do
      described_class.run(on_clear: on_clear, always_ensure: always_ensure, logger: logger) do |frame|
        frame.mark_claimed!(true)
        frame.mark_result_obtained!
        frame.mark_recorded!
      end

      expect(on_clear_log).to be_empty
      expect(always_log).to eq([:called])
    end

    it "(5) claimed=true, recorded, intentional_retry=true, no finalize: on_clear fires" do
      described_class.run(on_clear: on_clear, always_ensure: always_ensure, logger: logger) do |frame|
        frame.mark_claimed!(true)
        frame.mark_result_obtained!
        frame.mark_recorded!
        frame.mark_intentional_retry!(true)
      end

      expect(on_clear_log).to eq([:called])
      expect(always_log).to eq([:called])
    end

    it "(6) full happy path: on_clear AND always_ensure both fire" do
      described_class.run(on_clear: on_clear, always_ensure: always_ensure, logger: logger) do |frame|
        frame.mark_claimed!(true)
        frame.mark_result_obtained!
        frame.mark_recorded!
        frame.mark_finalize_succeeded!
      end

      expect(on_clear_log).to eq([:called])
      expect(always_log).to eq([:called])
    end

    it "(7) intentional_retry=true but recorded=false preserves state" do
      described_class.run(on_clear: on_clear, always_ensure: always_ensure, logger: logger) do |frame|
        frame.mark_claimed!(true)
        frame.mark_result_obtained!
        frame.mark_intentional_retry!(true)
      end

      expect(on_clear_log).to be_empty
      expect(always_log).to eq([:called])
    end
  end

  describe "exception paths" do
    it "(8) block raises after claim, before result_obtained: on_clear + always_ensure run, exception re-raised" do
      expect {
        described_class.run(on_clear: on_clear, always_ensure: always_ensure, logger: logger) do |frame|
          frame.mark_claimed!(true)
          raise "boom"
        end
      }.to raise_error(RuntimeError, "boom")

      expect(on_clear_log).to eq([:called])
      expect(always_log).to eq([:called])
    end

    it "(9) block raises after recorded, no retry, no finalize: on_clear skipped, always_ensure fires, exception re-raised" do
      expect {
        described_class.run(on_clear: on_clear, always_ensure: always_ensure, logger: logger) do |frame|
          frame.mark_claimed!(true)
          frame.mark_result_obtained!
          frame.mark_recorded!
          raise "boom"
        end
      }.to raise_error(RuntimeError, "boom")

      expect(on_clear_log).to be_empty
      expect(always_log).to eq([:called])
    end

    it "(10) on_clear raises: logged, always_ensure still runs, host return preserved" do
      bad_on_clear = -> { raise "on_clear blew up" }
      result = described_class.run(on_clear: bad_on_clear, always_ensure: always_ensure, logger: logger) do |frame|
        frame.mark_claimed!(true)
        :host_return
      end

      expect(result).to eq(:host_return)
      expect(always_log).to eq([:called])
      expect(logger_io.string).to include("on_clear raised")
    end

    it "(11) always_ensure raises: logged, host return preserved" do
      bad_always = -> { raise "always blew up" }
      result = described_class.run(on_clear: on_clear, always_ensure: bad_always, logger: logger) do |frame|
        frame.mark_claimed!(true)
        :host_return
      end

      expect(result).to eq(:host_return)
      expect(on_clear_log).to eq([:called])
      expect(logger_io.string).to include("always_ensure raised")
    end

    it "(12) host block and on_clear both raise: host exception wins, always_ensure still runs" do
      bad_on_clear = -> { raise "on_clear blew up" }
      expect {
        described_class.run(on_clear: bad_on_clear, always_ensure: always_ensure, logger: logger) do |frame|
          frame.mark_claimed!(true)
          raise "host boom"
        end
      }.to raise_error(RuntimeError, "host boom")

      expect(always_log).to eq([:called])
      expect(logger_io.string).to include("on_clear raised")
    end
  end

  describe "ordering enforcement" do
    it "(13) mark_result_obtained! before mark_claimed!(true) raises OrderingError" do
      expect {
        described_class.run(logger: logger) do |frame|
          frame.mark_result_obtained!
        end
      }.to raise_error(Smith::Workflow::ExecutionFrame::OrderingError, /mark_result_obtained!/)
    end

    it "(14) mark_recorded! before mark_result_obtained! raises OrderingError" do
      expect {
        described_class.run(logger: logger) do |frame|
          frame.mark_claimed!(true)
          frame.mark_recorded!
        end
      }.to raise_error(Smith::Workflow::ExecutionFrame::OrderingError, /mark_recorded!/)
    end

    it "(15) mark_finalize_succeeded! before mark_recorded! raises OrderingError" do
      expect {
        described_class.run(logger: logger) do |frame|
          frame.mark_claimed!(true)
          frame.mark_result_obtained!
          frame.mark_finalize_succeeded!
        end
      }.to raise_error(Smith::Workflow::ExecutionFrame::OrderingError, /mark_finalize_succeeded!/)
    end

    it "(16) mark_intentional_retry! after mark_claimed!(false) raises OrderingError" do
      expect {
        described_class.run(logger: logger) do |frame|
          frame.mark_claimed!(false)
          frame.mark_intentional_retry!(true)
        end
      }.to raise_error(Smith::Workflow::ExecutionFrame::OrderingError, /mark_intentional_retry!/)
    end

    it "(17) idempotent re-mark_claimed!(false) does NOT raise" do
      expect {
        described_class.run(logger: logger) do |frame|
          frame.mark_claimed!(false)
          frame.mark_claimed!(false)
        end
      }.not_to raise_error
    end

    it "mark_claimed! called twice with conflicting values raises" do
      expect {
        described_class.run(logger: logger) do |frame|
          frame.mark_claimed!(true)
          frame.mark_claimed!(false)
        end
      }.to raise_error(Smith::Workflow::ExecutionFrame::OrderingError, /conflicting/)
    end

    it "(18) OrderingError is NOT a subclass of Smith::WorkflowError" do
      expect(Smith::Workflow::ExecutionFrame::OrderingError.ancestors).not_to include(Smith::WorkflowError)
      expect(Smith::Workflow::ExecutionFrame::OrderingError.ancestors).to include(Smith::Error)
    end

    it "AlreadyRun is NOT a subclass of Smith::WorkflowError" do
      expect(Smith::Workflow::ExecutionFrame::AlreadyRun.ancestors).not_to include(Smith::WorkflowError)
      expect(Smith::Workflow::ExecutionFrame::AlreadyRun.ancestors).to include(Smith::Error)
    end
  end

  describe "readers" do
    it "(20) every reader returns false before any mark" do
      frame = described_class.new
      expect(frame.claimed?).to be false
      expect(frame.result_obtained?).to be false
      expect(frame.recorded?).to be false
      expect(frame.intentional_retry?).to be false
      expect(frame.finalize_succeeded?).to be false
      expect(frame.should_clear?).to be false
    end

    it "(21) intentional_retry? toggles with mark_intentional_retry!(true/false)" do
      frame = described_class.new
      frame.mark_claimed!(true)
      frame.mark_intentional_retry!(true)
      expect(frame.intentional_retry?).to be true
      frame.mark_intentional_retry!(false)
      expect(frame.intentional_retry?).to be false
    end

    it "(22) host reads frame.intentional_retry? inside its rescue path" do
      captured = nil
      described_class.run(on_clear: on_clear, always_ensure: always_ensure, logger: logger) do |frame|
        frame.mark_claimed!(true)
        frame.mark_result_obtained!
        frame.mark_recorded!
        frame.mark_intentional_retry!(true)
        captured = frame.intentional_retry?
      end
      expect(captured).to be true
    end
  end

  describe "return value" do
    it "(23) block returns nil: ExecutionFrame.run returns nil" do
      result = described_class.run(on_clear: on_clear, logger: logger) { |frame| frame.mark_claimed!(true); nil }
      expect(result).to be_nil
    end

    it "(24) block returns a Hash: ExecutionFrame.run returns it byte-identical" do
      payload = { ok: true, count: 3 }
      result = described_class.run(on_clear: on_clear, logger: logger) do |frame|
        frame.mark_claimed!(true); frame.mark_result_obtained!; frame.mark_recorded!; frame.mark_finalize_succeeded!
        payload
      end
      expect(result).to equal(payload)
    end

    it "(25) early return before any mark: no callbacks fire" do
      result = described_class.run(on_clear: on_clear, always_ensure: always_ensure, logger: logger) { |frame| nil }
      expect(result).to be_nil
      expect(on_clear_log).to be_empty
      expect(always_log).to be_empty
    end
  end

  describe "workflow: callable resolver" do
    let(:fake_workflow) do
      Class.new do
        attr_reader :cleared

        def initialize
          @cleared = false
        end

        def clear_persisted!
          @cleared = true
        end
      end.new
    end

    it "(26) workflow: instance: clear_persisted! is called once on clear" do
      described_class.run(workflow: fake_workflow, logger: logger) do |frame|
        frame.mark_claimed!(true)
      end
      expect(fake_workflow.cleared).to be true
    end

    it "(27) workflow: Proc returns nil initially then a real handle (lazy resolve)" do
      handle = nil
      resolver = -> { handle }

      described_class.run(workflow: resolver, logger: logger) do |frame|
        frame.mark_claimed!(true)
        handle = fake_workflow
      end

      expect(fake_workflow.cleared).to be true
    end

    it "(28) workflow: Proc returns nil even at ensure-time: log + skip without raising" do
      resolver = -> { nil }

      expect {
        described_class.run(workflow: resolver, logger: logger) do |frame|
          frame.mark_claimed!(true)
        end
      }.not_to raise_error

      expect(logger_io.string).to include("workflow resolver returned nil")
    end

    it "(29) workflow: + on_clear: both passed: on_clear wins, resolver NOT invoked" do
      resolver_called = false
      resolver = -> { resolver_called = true; fake_workflow }

      described_class.run(workflow: resolver, on_clear: on_clear, logger: logger) do |frame|
        frame.mark_claimed!(true)
      end

      expect(on_clear_log).to eq([:called])
      expect(resolver_called).to be false
      expect(fake_workflow.cleared).to be false
    end
  end

  describe "always_ensure ordering" do
    it "(30) always_ensure runs AFTER on_clear" do
      call_order = []
      ord_on_clear = -> { call_order << :on_clear }
      ord_always = -> { call_order << :always_ensure }

      described_class.run(on_clear: ord_on_clear, always_ensure: ord_always, logger: logger) do |frame|
        frame.mark_claimed!(true)
      end

      expect(call_order).to eq([:on_clear, :always_ensure])
    end

    it "(32) always_ensure does NOT run when claimed=false" do
      described_class.run(on_clear: on_clear, always_ensure: always_ensure, logger: logger) do |frame|
        frame.mark_claimed!(false)
      end
      expect(always_log).to be_empty
    end

    it "(33) always_ensure runs even when on_clear raised" do
      bad_on_clear = -> { raise "kaboom" }
      described_class.run(on_clear: bad_on_clear, always_ensure: always_ensure, logger: logger) do |frame|
        frame.mark_claimed!(true)
      end
      expect(always_log).to eq([:called])
    end
  end

  describe "logger fallback chain" do
    it "(34) explicit logger: captures on_clear failure" do
      bad_on_clear = -> { raise "boom" }
      described_class.run(on_clear: bad_on_clear, logger: logger) do |frame|
        frame.mark_claimed!(true)
      end
      expect(logger_io.string).to include("on_clear raised")
    end

    it "(35) logger: nil and Smith.config.logger present: Smith.config.logger captures" do
      smith_log_io = StringIO.new
      old_logger = Smith.config.logger
      Smith.config.logger = Logger.new(smith_log_io)
      begin
        bad_on_clear = -> { raise "boom" }
        described_class.run(on_clear: bad_on_clear) do |frame|
          frame.mark_claimed!(true)
        end
        expect(smith_log_io.string).to include("on_clear raised")
      ensure
        Smith.config.logger = old_logger
      end
    end

    it "(36) logger: nil AND Smith.config.logger nil: falls back to Logger.new($stderr)" do
      old_logger = Smith.config.logger
      Smith.config.logger = nil
      begin
        bad_on_clear = -> { raise "boom" }
        captured = StringIO.new
        original_stderr = $stderr
        $stderr = captured
        begin
          described_class.run(on_clear: bad_on_clear) do |frame|
            frame.mark_claimed!(true)
          end
        ensure
          $stderr = original_stderr
        end
        expect(captured.string).to include("on_clear raised")
      ensure
        Smith.config.logger = old_logger
      end
    end
  end

  describe "single-use" do
    it "(37) second invocation of .run on same instance raises AlreadyRun" do
      frame = described_class.new(on_clear: on_clear, logger: logger)
      frame.run { |f| f.mark_claimed!(true) }
      expect {
        frame.run { |f| f.mark_claimed!(true) }
      }.to raise_error(Smith::Workflow::ExecutionFrame::AlreadyRun)
    end

    it "(38) finish! called twice: callbacks invoked at most once" do
      frame = described_class.new(on_clear: on_clear, always_ensure: always_ensure, logger: logger)
      frame.mark_claimed!(true)
      first = frame.finish!
      second = frame.finish!
      expect(first).to be true
      expect(second).to be false
      expect(on_clear_log).to eq([:called])
      expect(always_log).to eq([:called])
    end
  end

  describe "integration with Smith::PersistenceAdapters::Memory" do
    let(:adapter) { Smith::PersistenceAdapters::Memory.new }
    let(:workflow_class) do
      stub_const("SpecExecutionFrameWorkflow", Class.new(Smith::Workflow) {
        initial_state :idle
        state :done

        transition :finish, from: :idle, to: :done do
          compute { |_step| "ok" }
        end
      })
      SpecExecutionFrameWorkflow
    end

    around do |example|
      previous = Smith.config.persistence_adapter
      Smith.config.persistence_adapter = adapter
      example.run
      Smith.config.persistence_adapter = previous
    end

    it "(40 happy) clears the persistence key after a successful run" do
      key = "spec:frame:happy"
      workflow_class.run_persisted!(key: key, adapter: adapter, clear: false)
      expect(adapter.fetch(key)).not_to be_nil

      handle = workflow_class.restore(key, adapter: adapter)
      described_class.run(workflow: handle, logger: logger) do |frame|
        frame.mark_claimed!(true)
        frame.mark_result_obtained!
        frame.mark_recorded!
        frame.mark_finalize_succeeded!
      end

      expect(adapter.fetch(key)).to be_nil
    end

    it "(40 mid-failure) preserves the persistence key after a finalize-raises path" do
      key = "spec:frame:fail"
      workflow_class.run_persisted!(key: key, adapter: adapter, clear: false)
      handle = workflow_class.restore(key, adapter: adapter)

      expect {
        described_class.run(workflow: handle, logger: logger) do |frame|
          frame.mark_claimed!(true)
          frame.mark_result_obtained!
          frame.mark_recorded!
          raise "boom"
        end
      }.to raise_error(RuntimeError, "boom")

      expect(adapter.fetch(key)).not_to be_nil
    end

    it "(40 lazy resolver) pre-run early-return with workflow: callable clears via the lazy resolver" do
      key = "spec:frame:lazy"
      workflow_class.run_persisted!(key: key, adapter: adapter, clear: false)
      expect(adapter.fetch(key)).not_to be_nil

      handle = nil
      resolver = -> { handle ||= workflow_class.restore(key, adapter: adapter) }

      described_class.run(workflow: resolver, logger: logger) do |frame|
        frame.mark_claimed!(true)
      end

      expect(adapter.fetch(key)).to be_nil
    end
  end
end
