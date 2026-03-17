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
end
