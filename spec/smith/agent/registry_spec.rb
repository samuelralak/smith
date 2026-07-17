# frozen_string_literal: true

RSpec.describe "Smith::Agent registry contract" do
  let(:registry) { require_const("Smith::Agent::Registry") }
  let(:agent_class) { require_const("Smith::Agent") }

  after { registry.clear! }

  def make_agent(name)
    klass = Class.new(agent_class)
    klass.define_singleton_method(:name) { name }
    klass
  end

  it "provides a registry namespace used by workflow execute bindings" do
    expect(registry).not_to be_nil
    expect(registry).to respond_to(:find)
    expect(registry).to respond_to(:clear!)
    expect(registry).to respond_to(:delete)
    expect(registry).to respond_to(:ensure_registered)
    expect(registry).to respond_to(:binding_for)
  end

  it "supports explicit registration names via register_as" do
    concrete = with_stubbed_class("SpecRegisteredAgent", agent_class) do
      register_as :spec_registered_agent
    end

    expect(concrete).to be < agent_class
  end

  it "supports staging a registration name before atomic publication" do
    concrete = make_agent("Test::StagedAgent")

    result = concrete.register_as(:staged_agent, publish: false)

    expect(result).to equal(concrete)
    expect(concrete.register_as).to eq(:staged_agent)
    expect(registry.find(:staged_agent)).to be_nil

    concrete.freeze
    concrete.publish_registration!

    expect(registry.find(:staged_agent)).to equal(concrete)
  end

  it "owns an immutable staged string identity" do
    concrete = make_agent("Test::StringStagedAgent")
    source_name = String.new("string_staged_agent")

    concrete.register_as(source_name, publish: false)
    source_name.replace("different_agent")

    expect(concrete.register_as).to eq("string_staged_agent")
    expect(concrete.register_as).to be_frozen
    concrete.freeze
    expect { concrete.register_as << "_changed" }.to raise_error(FrozenError)

    concrete.publish_registration!

    expect(registry.find(:string_staged_agent)).to equal(concrete)
    expect(registry.find(:different_agent)).to be_nil
  end

  it "publishes only the staged identity" do
    concrete = make_agent("Test::ExactStagedAgent")
    concrete.register_as(:exact_staged_agent, publish: false)
    concrete.freeze

    concrete.publish_registration!

    expect(registry.find(:exact_staged_agent)).to equal(concrete)
    expect(registry.find(:different_staged_agent)).to be_nil
  end

  it "preserves the existing binding when staged publication collides" do
    existing = make_agent("Test::ExistingStagedAgent")
    candidate = make_agent("Test::CollidingStagedAgent")
    existing.register_as(:staged_collision)
    candidate.register_as(:staged_collision, publish: false)
    candidate.freeze

    expect { candidate.publish_registration! }
      .to raise_error(Smith::AgentRegistryError, /collision/)
    expect(registry.find(:staged_collision)).to equal(existing)
  end

  it "atomically resolves competing staged publications" do
    candidates = [
      make_agent("Test::ConcurrentStagedAgentA"),
      make_agent("Test::ConcurrentStagedAgentB")
    ]
    candidates.each do |candidate|
      candidate.register_as(:concurrent_staged_agent, publish: false)
      candidate.freeze
    end

    ready = Queue.new
    start = Queue.new
    results = Queue.new
    threads = candidates.map do |candidate|
      Thread.new do
        ready << true
        start.pop
        candidate.publish_registration!
        results << candidate
      rescue Smith::AgentRegistryError => e
        results << e
      end
    end

    candidates.size.times { ready.pop }
    candidates.size.times { start << true }
    threads.each(&:join)
    outcomes = candidates.size.times.map { results.pop }
    published = outcomes.grep(Class)

    expect(published.size).to eq(1)
    expect(outcomes.grep(Smith::AgentRegistryError).size).to eq(1)
    expect(registry.find(:concurrent_staged_agent)).to equal(published.first)
    expect(registry.find(:concurrent_staged_agent)).to be_frozen
  end

  it "requires a staged identity before publication" do
    concrete = make_agent("Test::UnstagedAgent")

    expect { concrete.publish_registration! }
      .to raise_error(Smith::AgentRegistryError, "agent registration identity is not configured")
  end

  it "validates staged registration names before storing them" do
    concrete = make_agent("Test::InvalidRegistrationNameAgent")

    expect { concrete.register_as(Object.new, publish: false) }
      .to raise_error(TypeError, "agent registration name must respond to #to_sym")
    expect(concrete.register_as).to be_nil
  end

  it "rejects an ambiguous staged publication flag" do
    concrete = make_agent("Test::InvalidStagedAgent")

    expect { concrete.register_as(:invalid_staged_agent, publish: nil) }
      .to raise_error(ArgumentError, "publish must be true or false")
    expect(concrete.register_as).to be_nil
    expect(registry.find(:invalid_staged_agent)).to be_nil
  end

  it "supports clearing registered bindings for isolated runtimes" do
    with_stubbed_class("SpecClearableRegisteredAgent", agent_class) do
      register_as :spec_clearable_registered_agent
    end

    expect(registry.find(:spec_clearable_registered_agent)).not_to be_nil

    registry.clear!

    expect(registry.find(:spec_clearable_registered_agent)).to be_nil
  end

  describe ".delete" do
    it "removes one binding" do
      klass = make_agent("Test::DeleteAgent")
      registry.ensure_registered(:delete_test, klass)
      expect(registry.find(:delete_test)).to equal(klass)

      registry.delete(:delete_test)
      expect(registry.find(:delete_test)).to be_nil
    end

    it "normalizes symbol and string keys" do
      klass = make_agent("Test::NormalizeAgent")
      registry.ensure_registered(:normalize_test, klass)

      registry.delete("normalize_test")
      expect(registry.find(:normalize_test)).to be_nil
    end

    it "no-ops for missing key" do
      expect { registry.delete(:nonexistent) }.not_to raise_error
    end
  end

  describe ".ensure_registered" do
    it "registers a missing binding" do
      klass = make_agent("Test::NewAgent")
      registry.ensure_registered(:new_agent, klass)
      expect(registry.find(:new_agent)).to equal(klass)
    end

    it "no-ops when same object is already bound" do
      klass = make_agent("Test::SameAgent")
      registry.ensure_registered(:same_agent, klass)
      registry.ensure_registered(:same_agent, klass)
      expect(registry.find(:same_agent)).to equal(klass)
    end

    it "replaces stale same-name class (Rails reload simulation)" do
      old_klass = make_agent("Test::ReloadAgent")
      new_klass = make_agent("Test::ReloadAgent")

      registry.ensure_registered(:reload_agent, old_klass)
      registry.ensure_registered(:reload_agent, new_klass)

      expect(registry.find(:reload_agent)).to equal(new_klass)
      expect(registry.find(:reload_agent)).not_to equal(old_klass)
    end

    it "raises AgentRegistryError for different class name" do
      klass_a = make_agent("Test::AgentA")
      klass_b = make_agent("Test::AgentB")

      registry.ensure_registered(:collision_key, klass_a)

      expect do
        registry.ensure_registered(:collision_key, klass_b)
      end.to raise_error(Smith::AgentRegistryError, /collision/)
    end

    it "raises AgentRegistryError for anonymous classes on collision" do
      anon_a = Class.new(agent_class)
      anon_b = Class.new(agent_class)

      registry.ensure_registered(:anon_key, anon_a)

      expect do
        registry.ensure_registered(:anon_key, anon_b)
      end.to raise_error(Smith::AgentRegistryError)
    end

    it "validates input — rejects non-Class" do
      expect do
        registry.ensure_registered(:bad_key, "not a class")
      end.to raise_error(Smith::AgentRegistryError, /Smith::Agent subclass/)
    end

    it "validates input — rejects non-Agent class" do
      expect do
        registry.ensure_registered(:bad_key, String)
      end.to raise_error(Smith::AgentRegistryError, /Smith::Agent subclass/)
    end
  end

  describe ".register_as reload safety" do
    it "handles full reload simulation without raising" do
      old_klass = make_agent("Test::ReloadableAgent")
      old_klass.register_as :reloadable_agent

      new_klass = make_agent("Test::ReloadableAgent")
      new_klass.register_as :reloadable_agent

      expect(registry.find(:reloadable_agent)).to equal(new_klass)
    end
  end

  describe "overridden .register" do
    it "delegates agent classes to ensure_registered (reload-safe)" do
      old_klass = make_agent("Test::RegisterOverrideAgent")
      registry.register(:register_override, old_klass)

      new_klass = make_agent("Test::RegisterOverrideAgent")
      registry.register(:register_override, new_klass)

      expect(registry.find(:register_override)).to equal(new_klass)
    end

    it "preserves generic Dry::Container for non-agents" do
      registry.register(:plain_value, "hello")
      expect(registry.find(:plain_value)).to eq("hello")
    end

    it "raises on agent collision via register" do
      klass_a = make_agent("Test::CollisionA")
      klass_b = make_agent("Test::CollisionB")

      registry.register(:collision_register, klass_a)

      expect do
        registry.register(:collision_register, klass_b)
      end.to raise_error(Smith::AgentRegistryError, /collision/)
    end

    it "preserves block-based registration" do
      registry.register(:block_value) { "lazy_result" }
      expect(registry.find(:block_value)).to eq("lazy_result")
    end

    it "preserves options forwarding" do
      registry.register(:memoized_value, "static", call: false)
      expect(registry.find(:memoized_value)).to eq("static")
    end
  end

  describe "registry mutation boundary" do
    it "does not expose the mutable Dry::Container storage" do
      expect(registry).not_to respond_to(:_container)
      expect { registry._container }.to raise_error(NoMethodError)
    end

    it "preserves merge and namespace behavior" do
      source = Dry::Container.new
      source.register(:merged_agent, make_agent("Test::MergedAgent"), call: false)
      namespaced_agent = make_agent("Test::NamespacedAgent")

      registry.merge(source)
      registry.namespace(:review) { register(:writer, namespaced_agent) }

      expect(registry.find(:merged_agent).name).to eq("Test::MergedAgent")
      expect(registry.find("review.writer").name).to eq("Test::NamespacedAgent")
    end
  end

  describe ".binding_for" do
    it "returns concrete agent bindings without resolving lazy entries" do
      calls = 0
      klass = make_agent("Test::BindingProbeAgent")

      registry.register(:concrete_binding_probe, klass)
      registry.register(:lazy_binding_probe) do
        calls += 1
        klass
      end

      concrete = registry.binding_for(:concrete_binding_probe)
      lazy = registry.binding_for(:lazy_binding_probe)

      expect(concrete).to include(key: "concrete_binding_probe", agent_class: klass, call: false)
      expect(lazy).to include(key: "lazy_binding_probe", agent_class: nil, call: true)
      expect(calls).to eq(0)
    end

    it "reports non-agent container bindings without coercing them" do
      registry.register(:plain_binding_probe, "plain")

      binding = registry.binding_for(:plain_binding_probe)

      expect(binding).to include(key: "plain_binding_probe", agent_class: nil, call: false, raw_binding: "plain")
    end
  end

  describe ".bindings" do
    it "enumerates registered bindings without resolving lazy entries" do
      calls = 0
      klass = make_agent("Test::BindingsProbeAgent")

      registry.register(:concrete_bindings_probe, klass)
      registry.register(:lazy_bindings_probe) do
        calls += 1
        klass
      end

      bindings = registry.bindings

      expect(bindings.fetch("concrete_bindings_probe")).to include(agent_class: klass, call: false)
      expect(bindings.fetch("lazy_bindings_probe")).to include(agent_class: nil, call: true)
      expect(calls).to eq(0)
    end
  end

  describe "nested block resolution (re-entrant safety)" do
    it "resolves block-backed entries that re-enter the registry without deadlock" do
      registry.register(:inner, "ok")
      registry.register(:outer) { registry.find(:inner) }

      expect(registry.find(:outer)).to eq("ok")
    end

    it "fetch! resolves block-backed entries that re-enter the registry" do
      registry.register(:inner_fetch, "fetched")
      registry.register(:outer_fetch) { registry.fetch!(:inner_fetch) }

      expect(registry.find(:outer_fetch)).to eq("fetched")
    end
  end

  describe "mixed collision (agent vs non-agent)" do
    it "ensure_registered raises AgentRegistryError when key holds a plain value" do
      registry.register(:mixed_key, "plain_value")
      klass = make_agent("Test::MixedAgent")

      expect do
        registry.ensure_registered(:mixed_key, klass)
      end.to raise_error(Smith::AgentRegistryError, /collision/)
    end

    it "overridden register raises AgentRegistryError when key holds a plain value" do
      registry.register(:mixed_register, "plain_value")
      klass = make_agent("Test::MixedRegisterAgent")

      expect do
        registry.register(:mixed_register, klass)
      end.to raise_error(Smith::AgentRegistryError, /collision/)
    end
  end
end
