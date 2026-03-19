# frozen_string_literal: true

RSpec.describe "Smith artifacts operational contract" do
  it "exposes the documented artifact store methods" do
    expect(Smith).to respond_to(:artifacts)

    artifact_store = Smith.artifacts

    %i[store fetch expired].each do |method_name|
      expect(artifact_store).to respond_to(method_name), "expected artifact store to implement ##{method_name}"
    end
  end

  it "resolves Smith.artifacts to the configured artifact store" do
    custom_store = require_const("Smith::Artifacts::Memory").new
    original_store = Smith.config.artifact_store

    Smith.configure do |config|
      config.artifact_store = custom_store
    end

    expect(Smith.artifacts).to be(custom_store)
  ensure
    Smith.configure do |config|
      config.artifact_store = original_store
    end
  end

  it "scopes expired refs to the current execution wrapper for shared backends" do
    scoped_store_class = require_const("Smith::Artifacts::ScopedStore")
    backend_refs = []

    shared_backend = Object.new
    shared_backend.define_singleton_method(:store) do |_data, content_type: "application/octet-stream", execution_namespace: nil|
      ref = "backend-ref-#{backend_refs.length + 1}"
      backend_refs << { ref: ref, content_type: content_type, execution_namespace: execution_namespace }
      ref
    end
    shared_backend.define_singleton_method(:fetch) { |_ref| nil }
    shared_backend.define_singleton_method(:expired) do |retention: nil, execution_namespace: nil|
      matching = backend_refs
      matching = matching.select { |e| e[:execution_namespace] == execution_namespace } if execution_namespace
      matching.map { |entry| entry[:ref] }
    end

    first_scope = scoped_store_class.new(backend: shared_backend, namespace: "execution-a")
    second_scope = scoped_store_class.new(backend: shared_backend, namespace: "execution-b")

    first_ref = first_scope.store("first")
    second_ref = second_scope.store("second")

    expect(first_scope.expired(retention: 60)).to eq([first_ref])
    expect(second_scope.expired(retention: 60)).to eq([second_ref])
  end
end
