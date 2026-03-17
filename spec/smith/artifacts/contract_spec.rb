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
end
