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
  end

  it "supports explicit registration names via register_as" do
    concrete = with_stubbed_class("SpecRegisteredAgent", agent_class) do
      register_as :spec_registered_agent
    end

    expect(concrete).to be < agent_class
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

      expect {
        registry.ensure_registered(:collision_key, klass_b)
      }.to raise_error(Smith::AgentRegistryError, /collision/)
    end

    it "raises AgentRegistryError for anonymous classes on collision" do
      anon_a = Class.new(agent_class)
      anon_b = Class.new(agent_class)

      registry.ensure_registered(:anon_key, anon_a)

      expect {
        registry.ensure_registered(:anon_key, anon_b)
      }.to raise_error(Smith::AgentRegistryError)
    end

    it "validates input — rejects non-Class" do
      expect {
        registry.ensure_registered(:bad_key, "not a class")
      }.to raise_error(Smith::AgentRegistryError, /Smith::Agent subclass/)
    end

    it "validates input — rejects non-Agent class" do
      expect {
        registry.ensure_registered(:bad_key, String)
      }.to raise_error(Smith::AgentRegistryError, /Smith::Agent subclass/)
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

      expect {
        registry.register(:collision_register, klass_b)
      }.to raise_error(Smith::AgentRegistryError, /collision/)
    end

    it "preserves block-based registration" do
      registry.register(:block_value) { "lazy_result" }
      expect(registry.find(:block_value)).to eq("lazy_result")
    end
  end
end
