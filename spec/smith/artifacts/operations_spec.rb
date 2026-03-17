# frozen_string_literal: true

RSpec.describe "Smith artifacts operational contract" do
  it "exposes the documented artifact store methods" do
    expect(Smith).to respond_to(:artifacts)

    artifact_store = Smith.artifacts

    %i[store fetch expired].each do |method_name|
      expect(artifact_store).to respond_to(method_name), "expected artifact store to implement ##{method_name}"
    end
  end
end
