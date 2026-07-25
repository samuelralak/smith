# frozen_string_literal: true

RSpec.describe Smith::Tool::ExecutionBatchSourceCall do
  def call_with(id: "call", name: :probe, arguments: {}, thought_signature: nil)
    Data.define(:id, :name, :arguments, :thought_signature).new(id, name, arguments, thought_signature)
  end

  it "normalizes transport metadata to UTF-8" do
    source = described_class.capture(
      key: :call,
      tool_call: call_with(
        id: "café".encode(Encoding::UTF_16LE),
        name: "probe".encode(Encoding::UTF_16LE),
        thought_signature: "signed".encode(Encoding::UTF_16LE)
      )
    )

    expect(source.tool_call_id).to eq("café")
    expect(source.name).to eq("probe")
    expect(source.thought_signature).to eq("signed")
    expect([source.tool_call_id, source.name, source.thought_signature]).to all(satisfy do |value|
      value.encoding == Encoding::UTF_8 && value.valid_encoding?
    end)
  end

  it "normalizes a non-UTF-8 Symbol name into the executable name" do
    encoded_name = "probe".encode(Encoding::UTF_16LE).to_sym

    source = described_class.capture(
      key: :call,
      tool_call: call_with(name: encoded_name)
    )

    expect(source.name).to eq(:probe)
    expect(source.canonical_name).to eq("probe")
    expect(source.canonical_name.encoding).to eq(Encoding::UTF_8)
    expect(source.canonical_name).to be_valid_encoding
  end

  it "rejects metadata that cannot be represented as UTF-8" do
    invalid = "\xFF".b

    expect do
      described_class.capture(key: :call, tool_call: call_with(id: invalid))
    end.to raise_error(Smith::Error, /valid UTF-8 text/)
  end

  it "rejects oversized source metadata before transcoding it" do
    oversized = ("x" * (described_class::MAX_METADATA_BYTES + 1)).encode(Encoding::UTF_16LE)

    expect do
      described_class.capture(key: :call, tool_call: call_with(id: oversized))
    end.to raise_error(Smith::Error, /tool call id exceeds/)
  end
end
