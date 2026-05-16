# frozen_string_literal: true

# Pins the per-workflow persistence_ttl DSL contract: workflow classes
# can override Smith.config.persistence_ttl. Workflow#persist! resolves
# the effective TTL (class DSL > global config > nil) and forwards it
# to the adapter as a `ttl:` kwarg only when non-nil, so external
# duck-typed adapters that don't accept `ttl:` keep working as long as
# the host doesn't opt into TTL.

RSpec.describe "Smith::Workflow per-workflow persistence_ttl DSL" do
  let(:recording_adapter_class) do
    Class.new do
      attr_reader :store_calls, :store_versioned_calls

      def initialize
        @store_calls = []
        @store_versioned_calls = []
      end

      def store(key, payload, **kwargs)
        @store_calls << { key: key, payload: payload, kwargs: kwargs }
      end

      def fetch(_key); end
      def delete(_key); end

      def store_versioned(key, payload, expected_version:, **kwargs)
        @store_versioned_calls << {
          key: key, payload: payload, expected_version: expected_version, kwargs: kwargs
        }
      end
    end
  end

  let(:versioned_adapter) { recording_adapter_class.new }
  let(:non_versioned_adapter_class) do
    Class.new do
      attr_reader :store_calls
      def initialize; @store_calls = []; end
      def store(key, payload, **kwargs)
        @store_calls << { key: key, payload: payload, kwargs: kwargs }
      end
      def fetch(_key); end
      def delete(_key); end
    end
  end
  let(:non_versioned_adapter) { non_versioned_adapter_class.new }

  let(:workflow_class) do
    Class.new(Smith::Workflow) do
      persistence_key { |_ctx| "workflow:ttl-test" }
      initial_state :idle
      state :done
      transition :finish, from: :idle, to: :done
    end
  end

  before do
    @original_global_ttl = Smith.config.persistence_ttl
    Smith.config.persistence_ttl = nil
    allow(Smith.config.logger).to receive(:warn) if Smith.config.logger
  end

  after do
    Smith.config.persistence_ttl = @original_global_ttl
    Smith::PersistenceAdapters.instance_variable_set(:@_warned_classes, Set.new)
  end

  describe "DSL semantics" do
    it "returns nil by default" do
      expect(workflow_class.persistence_ttl).to be_nil
    end

    it "accepts a positive Integer" do
      klass = Class.new(Smith::Workflow) { persistence_ttl 60 }
      expect(klass.persistence_ttl).to eq(60)
    end

    it "accepts a positive Float" do
      klass = Class.new(Smith::Workflow) { persistence_ttl 0.5 }
      expect(klass.persistence_ttl).to eq(0.5)
    end

    it "rejects zero" do
      expect {
        Class.new(Smith::Workflow) { persistence_ttl 0 }
      }.to raise_error(ArgumentError, /must be a positive Numeric/)
    end

    it "rejects negative" do
      expect {
        Class.new(Smith::Workflow) { persistence_ttl(-1) }
      }.to raise_error(ArgumentError, /must be a positive Numeric/)
    end

    it "rejects non-Numeric" do
      expect {
        Class.new(Smith::Workflow) { persistence_ttl "30" }
      }.to raise_error(ArgumentError, /must be a positive Numeric/)
    end

    it "propagates through class inheritance" do
      parent = Class.new(Smith::Workflow) { persistence_ttl 60 }
      child = Class.new(parent)
      expect(child.persistence_ttl).to eq(60)
    end

    it "allows a child class to override its parent's TTL" do
      parent = Class.new(Smith::Workflow) { persistence_ttl 60 }
      child = Class.new(parent) { persistence_ttl 120 }
      expect(parent.persistence_ttl).to eq(60)
      expect(child.persistence_ttl).to eq(120)
    end
  end

  describe "Workflow#persist! resolution precedence" do
    it "forwards the class-level TTL to a versioned adapter" do
      klass = Class.new(workflow_class) { persistence_ttl 90 }
      workflow = klass.new
      workflow.persist!("workflow:ttl-test", adapter: versioned_adapter)

      call = versioned_adapter.store_versioned_calls.last
      expect(call[:kwargs]).to eq(ttl: 90)
    end

    it "forwards the class-level TTL to a non-versioned adapter (fallback path)" do
      klass = Class.new(workflow_class) { persistence_ttl 90 }
      workflow = klass.new
      workflow.persist!("workflow:ttl-test", adapter: non_versioned_adapter)

      call = non_versioned_adapter.store_calls.last
      expect(call[:kwargs]).to eq(ttl: 90)
    end

    it "falls back to Smith.config.persistence_ttl when the class-level DSL is nil" do
      Smith.config.persistence_ttl = 45
      workflow = workflow_class.new
      workflow.persist!("workflow:ttl-test", adapter: versioned_adapter)

      call = versioned_adapter.store_versioned_calls.last
      expect(call[:kwargs]).to eq(ttl: 45)
    end

    it "class-level DSL wins over Smith.config.persistence_ttl" do
      Smith.config.persistence_ttl = 45
      klass = Class.new(workflow_class) { persistence_ttl 90 }
      workflow = klass.new
      workflow.persist!("workflow:ttl-test", adapter: versioned_adapter)

      call = versioned_adapter.store_versioned_calls.last
      expect(call[:kwargs]).to eq(ttl: 90)
    end

    it "omits the ttl: kwarg entirely when neither class DSL nor global config is set" do
      workflow = workflow_class.new
      workflow.persist!("workflow:ttl-test", adapter: versioned_adapter)

      call = versioned_adapter.store_versioned_calls.last
      expect(call[:kwargs]).to eq({})
      expect(call[:kwargs]).not_to have_key(:ttl)
    end

    it "preserves backward compat: external adapters with bare store(key, payload) keep working when TTL is nil" do
      bare_adapter = Class.new do
        attr_reader :calls
        def initialize; @calls = []; end
        # No ttl: kwarg, no **kwargs splat. Strictly the REQUIRED_METHODS contract.
        def store(key, payload); @calls << [key, payload]; end
        def fetch(_key); end
        def delete(_key); end
      end.new

      workflow = workflow_class.new
      expect { workflow.persist!("workflow:ttl-test", adapter: bare_adapter) }.not_to raise_error
      expect(bare_adapter.calls.size).to eq(1)
      expect(bare_adapter.calls.last[0]).to eq("workflow:ttl-test")
      expect(bare_adapter.calls.last[1]).to be_a(String)
    end

    it "resolves TTL fresh on each persist! (host can mutate config between persists)" do
      workflow = workflow_class.new
      workflow.persist!("workflow:ttl-test", adapter: versioned_adapter)
      expect(versioned_adapter.store_versioned_calls.last[:kwargs]).to eq({})

      Smith.config.persistence_ttl = 30
      workflow.persist!("workflow:ttl-test", adapter: versioned_adapter)
      expect(versioned_adapter.store_versioned_calls.last[:kwargs]).to eq(ttl: 30)
    end
  end

  describe "end-to-end with Memory adapter" do
    it "honors per-workflow TTL through the real adapter" do
      memory = Smith::PersistenceAdapters::Memory.new
      klass = Class.new(workflow_class) { persistence_ttl 0.05 }
      workflow = klass.new

      workflow.persist!("workflow:ttl-test", adapter: memory)
      expect(memory.fetch("workflow:ttl-test")).to be_a(String)

      sleep(0.1)
      expect(memory.fetch("workflow:ttl-test")).to be_nil
    end

    it "honors Smith.config.persistence_ttl when class DSL is unset" do
      Smith.config.persistence_ttl = 0.05
      memory = Smith::PersistenceAdapters::Memory.new
      workflow = workflow_class.new

      workflow.persist!("workflow:ttl-test", adapter: memory)
      expect(memory.fetch("workflow:ttl-test")).to be_a(String)

      sleep(0.1)
      expect(memory.fetch("workflow:ttl-test")).to be_nil
    end
  end
end
