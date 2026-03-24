# frozen_string_literal: true

RSpec.describe "Smith configuration contract" do
  it "exposes the top-level configure API used throughout the architecture" do
    expect(Smith).to respond_to(:configure)
  end

  it "yields a configuration object with the documented artifact and trace settings" do
    yielded_config = nil

    Smith.configure do |config|
      yielded_config = config
    end

    expect(yielded_config).not_to be_nil

    %i[
      artifact_store=
      artifact_retention=
      artifact_encryption=
      artifact_tenant_isolation=
      persistence_adapter=
      persistence_options=
      trace_adapter=
      trace_transitions=
      trace_tool_calls=
      trace_token_usage=
      trace_cost=
      trace_fields=
      trace_content=
      trace_retention=
      trace_tenant_isolation=
    ].each do |method_name|
      expect(yielded_config).to respond_to(method_name), "expected config to implement ##{method_name}"
    end
  end

  it "keeps trace content opt-in by default" do
    expect(Smith.config.trace_content).to be(false)
  end

  it "enables structural trace fields by default" do
    expect(Smith.config.trace_transitions).to be(true)
    expect(Smith.config.trace_tool_calls).to be(true)
    expect(Smith.config.trace_token_usage).to be(true)
    expect(Smith.config.trace_cost).to be(true)
  end

  it "exposes symbol-based persistence adapter configuration with options" do
    original_adapter = Smith.config.persistence_adapter
    original_options = Smith.config.persistence_options

    Smith.configure do |config|
      config.persistence_adapter = :cache_store
      config.persistence_options = {
        store: instance_double("CacheStore"),
        namespace: "smith-test"
      }
    end

    expect(Smith.config.persistence_adapter).to eq(:cache_store)
    expect(Smith.config.persistence_options).to include(namespace: "smith-test")
  ensure
    Smith.configure do |config|
      config.persistence_adapter = original_adapter
      config.persistence_options = original_options
    end
  end

  it "caches the resolved persistence adapter until the config changes" do
    store = instance_double("CacheStore")
    original_adapter = Smith.config.persistence_adapter
    original_options = Smith.config.persistence_options

    Smith.configure do |config|
      config.persistence_adapter = :cache_store
      config.persistence_options = { store:, namespace: "smith-cache" }
    end

    first = Smith.persistence_adapter
    second = Smith.persistence_adapter
    expect(first).to equal(second)

    Smith.configure do |config|
      config.persistence_options = { store:, namespace: "smith-cache-2" }
    end

    third = Smith.persistence_adapter
    expect(third).not_to equal(first)
  ensure
    Smith.configure do |config|
      config.persistence_adapter = original_adapter
      config.persistence_options = original_options
    end
  end

  it "refreshes the resolved persistence adapter when persistence_options are mutated in place" do
    original_adapter = Smith.config.persistence_adapter
    original_options = Smith.config.persistence_options
    options = {
      store: instance_double("CacheStore"),
      namespace: "smith-cache"
    }

    Smith.configure do |config|
      config.persistence_adapter = :cache_store
      config.persistence_options = options
    end

    first = Smith.persistence_adapter
    Smith.config.persistence_options[:namespace] = "smith-cache-2"
    second = Smith.persistence_adapter

    expect(second).not_to equal(first)
  ensure
    Smith.configure do |config|
      config.persistence_adapter = original_adapter
      config.persistence_options = original_options
    end
  end
end
