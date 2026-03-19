# frozen_string_literal: true

RSpec.describe "Smith artifacts contract" do
  it "defines the artifact store namespace and documented built-in backends" do
    %w[
      Smith::Artifacts
      Smith::Artifacts::Memory
      Smith::Artifacts::File
    ].each do |path|
      expect(fetch_const(path)).not_to be_nil, "expected #{path} to be defined"
    end
  end

  it "exposes the top-level artifact store accessor used by agents" do
    expect(Smith).to respond_to(:artifacts)
  end

  it "supports execution-scoped backend writes and expiry filtering through the artifact-store interface" do
    scoped_store_class = require_const("Smith::Artifacts::ScopedStore")
    calls = []

    backend = Object.new
    backend.define_singleton_method(:store) do |data, content_type: "application/octet-stream", execution_namespace: nil|
      calls << [:store, data, content_type, execution_namespace]
      "inner-ref"
    end
    backend.define_singleton_method(:fetch) do |ref|
      calls << [:fetch, ref]
      "payload"
    end
    backend.define_singleton_method(:expired) do |retention: nil, execution_namespace: nil|
      calls << [:expired, retention, execution_namespace]
      ["inner-ref"]
    end

    store = scoped_store_class.new(backend: backend, namespace: "execution-123")

    expect(store.store("payload", content_type: "application/json")).to eq("execution-123:inner-ref")
    expect(store.fetch("execution-123:inner-ref")).to eq("payload")
    expect(store.expired(retention: 60)).to eq(["execution-123:inner-ref"])
    expect(calls).to eq(
      [
        [:store, "payload", "application/json", "execution-123"],
        [:fetch, "inner-ref"],
        [:expired, 60, "execution-123"]
      ]
    )
  end
end
