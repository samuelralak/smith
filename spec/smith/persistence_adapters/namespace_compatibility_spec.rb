# frozen_string_literal: true

RSpec.describe "Smith persistence adapter namespace compatibility" do
  it "preserves unnamespaced CacheStore keys when namespace is nil" do
    backend = instance_double("CacheBackend")
    allow(backend).to receive(:write)
    adapter = Smith::PersistenceAdapters::CacheStore.new(store: backend, namespace: nil)

    adapter.store("workflow:1", "payload")

    expect(backend).to have_received(:write).with("workflow:1", "payload")
  end

  it "copies CacheStore namespaces instead of retaining mutable strings" do
    backend = instance_double("CacheBackend")
    allow(backend).to receive(:write)
    namespace = String.new("stable")
    adapter = Smith::PersistenceAdapters::CacheStore.new(store: backend, namespace: namespace)
    namespace.replace("changed")

    adapter.store("workflow:1", "payload")

    expect(backend).to have_received(:write).with("stable:workflow:1", "payload")
  end

  it "preserves unnamespaced RedisStore keys when namespace is nil" do
    client = instance_double("RedisClient")
    allow(client).to receive(:set)
    adapter = Smith::PersistenceAdapters::RedisStore.new(redis: client, namespace: nil)

    adapter.store("workflow:1", "payload")

    expect(client).to have_received(:set).with("workflow:1", "payload")
  end

  it "copies RedisStore namespaces instead of retaining mutable strings" do
    client = instance_double("RedisClient")
    allow(client).to receive(:set)
    namespace = String.new("stable")
    adapter = Smith::PersistenceAdapters::RedisStore.new(redis: client, namespace: namespace)
    namespace.replace("changed")

    adapter.store("workflow:1", "payload")

    expect(client).to have_received(:set).with("stable:workflow:1", "payload")
  end
end
