# frozen_string_literal: true

RSpec.describe "Smith tracing contract" do
  it "defines the documented trace adapters" do
    %w[
      Smith::Trace
      Smith::Trace::Memory
      Smith::Trace::Logger
      Smith::Trace::OpenTelemetry
    ].each do |path|
      expect(fetch_const(path)).not_to be_nil, "expected #{path} to be defined"
    end
  end
end
