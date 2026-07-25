# frozen_string_literal: true

require "spec_helper"

RSpec.describe Smith::DiagnosticText do
  it "scrubs invalid encoding into bounded UTF-8" do
    value = "before\xFFafter".b.force_encoding(Encoding::UTF_8)

    result = described_class.capture(value, max_bytes: 64)

    expect(result).to be_valid_encoding
    expect(result.encoding).to eq(Encoding::UTF_8)
    expect(result).to include("before", "after")
    expect(result.bytesize).to be <= 64
    expect(result).to be_frozen
  end

  it "truncates without splitting a multibyte character" do
    result = described_class.capture("é" * 100, max_bytes: 32)

    expect(result).to be_valid_encoding
    expect(result.bytesize).to be <= 32
    expect(result).to end_with("...[truncated]")
  end
end
