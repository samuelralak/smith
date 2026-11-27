# frozen_string_literal: true

require "smith/evals"
require "tmpdir"

# The store interface's names, the lease every built-in store hands out, and
# the configuration's default store (slice-1a design, 4.1 and 9.1).
RSpec.describe Smith::Evals::Store do
  it "names the twelve methods of slice 1a, which both stores answer with keywords only" do
    expect(described_class::METHODS).to eq(
      %i[create_record read_header acquire_lease append_segment append_trial each_segment each_trial write_summary
         read_summary list_records request_cancel cancel_request]
    )
    [Smith::Evals::Stores::Memory.new, Smith::Evals::Stores::File.new(root: "unused")].each do |store|
      expect(described_class.store?(store)).to be(true)
      kinds = described_class::METHODS.flat_map { store.method(_1).parameters.map(&:first) }
      expect(kinds.uniq - %i[keyreq key block]).to eq([])
    end
    expect(described_class.store?(Object.new)).to be(false)
  end

  it "takes as a store only an object that answers every one of the twelve methods" do
    methods = described_class::METHODS
    partial = methods.map do |missing|
      Class.new { (methods - [missing]).each { |name| define_method(name) { |**| nil } } }.new
    end
    whole = Class.new { methods.each { |name| define_method(name) { |**| nil } } }.new

    expect(partial.map { described_class.store?(_1) }).to all(be(false))
    partial.each { |store| expect { Smith::Evals::Configuration.new.store = store }.to raise_error(ArgumentError) }
    expect(described_class.store?(whole)).to be(true)
  end

  # Slice 5a: the tuning methods sit beside the twelve, so a host store
  # without them still keeps eval runs.
  it "names the six tuning methods apart, which both stores answer with keywords only" do
    expect(described_class::TUNING_METHODS).to eq(
      %i[create_tuning read_tuning_header append_tuning_line each_tuning_line write_tuning_summary read_tuning_summary]
    )
    [Smith::Evals::Stores::Memory.new, Smith::Evals::Stores::File.new(root: "unused")].each do |store|
      expect(described_class.tuning?(store)).to be(true)
      kinds = described_class::TUNING_METHODS.flat_map { store.method(_1).parameters.map(&:first) }
      expect(kinds.uniq - %i[keyreq key block]).to eq([])
    end
    methods = described_class::METHODS
    eval_only = Class.new { methods.each { |name| define_method(name) { |**| nil } } }.new
    expect([described_class.store?(eval_only), described_class.tuning?(eval_only)]).to eq([true, false])
    named = described_class::TUNING_METHODS + methods - %i[acquire_lease request_cancel cancel_request]
    old_keywords = Class.new do
      named.each { |name| define_method(name) { |**| nil } }
      define_method(:acquire_lease) { |scope:, eval_run_id:| nil }
      define_method(:request_cancel) { |scope:, eval_run_id:, actor:, reason:| nil }
      define_method(:cancel_request) { |scope:, eval_run_id:| nil }
    end.new
    expect(described_class.tuning?(old_keywords)).to be(false)
  end

  # The pilot's store wraps a file store in a SimpleDelegator, whose
  # methods take any arguments: what a method accepts decides, one rule.
  it "takes a store that forwards the tuning run id, through ** or a delegator" do
    require "delegate"
    store = Smith::Evals::Stores::File.new(root: "unused")
    forwarding = Class.new(SimpleDelegator) do
      %i[acquire_lease request_cancel cancel_request].each do |name|
        define_method(name) { |**options| super(**options) }
      end
    end

    expect(described_class.tuning?(SimpleDelegator.new(store))).to be(true)
    expect(described_class.tuning?(forwarding.new(store))).to be(true)
  end

  it "defaults the configured store to a file store under tmp/smith-evals, created on its first write" do
    Dir.mktmpdir do |dir|
      Dir.chdir(dir) do
        config = Smith::Evals::Configuration.new

        expect(config.store).to be_a(Smith::Evals::Stores::File)
        expect(config.store.root).to eq(File.join(Dir.pwd, "tmp", "smith-evals"))
        expect(Dir.children(dir)).to eq([])
      end
    end
  end

  # A host that sets its own store never needs a working folder; the
  # default store is built when first read, and says why it cannot be.
  it "configures with the working folder gone: no default store, and a plain error when one is read" do
    Dir.mktmpdir do |dir|
      gone = File.join(dir, "gone")
      Dir.mkdir(gone)
      Dir.chdir(gone) do
        Dir.rmdir(gone)
        config = Smith::Evals::Configuration.new
        config.store = Smith::Evals::Stores::Memory.new

        expect(config.frozen_copy.store).to be_a(Smith::Evals::Stores::Memory)
        expect { Smith::Evals::Configuration.new.store }.to raise_error(ArgumentError, /working folder/)
      end
    end
  end

  it "refuses a configured store that does not answer the interface" do
    config = Smith::Evals::Configuration.new

    expect { config.store = Object.new }.to raise_error(ArgumentError, /store/)
    expect { config.store = nil }.to raise_error(ArgumentError, /store/)
    config.store = Smith::Evals::Stores::Memory.new
    expect(config.store).to be_a(Smith::Evals::Stores::Memory)
  end

  describe Smith::Evals::Store::Lease do
    it "releases once, from any thread, and says so" do
      calls = []
      lease = described_class.new(scope: { "tenant" => "t" }, eval_run_id: EvalRecords.run_id(1)) { calls << :released }

      expect(lease).not_to be_released
      4.times.map { Thread.new { lease.release } }.each(&:join)
      expect([lease.released?, calls, lease.eval_run_id, lease.scope])
        .to eq([true, [:released], EvalRecords.run_id(1), { "tenant" => "t" }])
    end

    it "names a tuning run's lease by its tuning run id" do
      lease = described_class.new(scope: {}, tuning_run_id: TuningRecords.run_id(1))

      expect([lease.tuning_run_id, lease.eval_run_id]).to eq([TuningRecords.run_id(1), nil])
    end
  end
end
