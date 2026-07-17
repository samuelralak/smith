# frozen_string_literal: true

RSpec.describe Smith do
  it "has a version number" do
    expect(Smith::VERSION).not_to be_nil
  end

  it "publishes its execution semantics version" do
    expect(Smith::EXECUTION_SEMANTICS_VERSION).to match(/\A[1-9]\d*\z/)
  end

  it "defines a top-level error class" do
    expect(Smith::Error).to be < StandardError
  end
end
