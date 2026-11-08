# frozen_string_literal: true

RSpec.describe Smith::Workflow::FailureRecordText do
  it "owns a bounded UTF-8 copy" do
    source = +"provider failed"

    captured = described_class.capture(source, limit: 64, label: "message")
    source.replace("changed")

    expect(captured).to eq("provider failed")
    expect(captured).to be_frozen
    expect(captured.encoding).to eq(Encoding::UTF_8)
  end

  it "uses native String operations for hostile subclasses" do
    hostile = Class.new(String) do
      def valid_encoding? = raise("should not be called")

      def bytesize = raise("should not be called")

      def to_s = raise("should not be called")
    end.new("provider failed")

    expect(described_class.capture(hostile, limit: 64, label: "message")).to eq("provider failed")
  end

  it "takes US-ASCII text and a Symbol's name as the UTF-8 text they are" do
    source = +"verify"
    source.force_encoding(Encoding::US_ASCII)

    [source, :verify].each do |value|
      captured = described_class.capture(value, limit: 64, label: "transition")

      expect(captured).to eq("verify")
      expect(captured.encoding).to eq(Encoding::UTF_8)
      expect(captured).to be_frozen
    end
    expect(source.encoding).to eq(Encoding::US_ASCII)
  end

  it "still rejects US-ASCII text with bytes outside it, and binary text" do
    ["verify\xFF".dup.force_encoding(Encoding::US_ASCII), "verify".b].each do |value|
      expect { described_class.capture(value, limit: 64, label: "transition") }
        .to raise_error(Smith::PersistedFailureInvalid, /transition is invalid/)
    end
  end

  it "rejects non-UTF-8 and oversized values" do
    expect do
      described_class.capture("failed".encode(Encoding::UTF_16LE), limit: 64, label: "message")
    end.to raise_error(Smith::PersistedFailureInvalid, /message is invalid/)

    expect do
      described_class.capture("x" * 65, limit: 64, label: "message")
    end.to raise_error(Smith::PersistedFailureInvalid, /message is invalid/)
  end

  describe "length normalization for message fields" do
    it "substitutes the shared placeholder for blank text" do
      captured = described_class.capture("", limit: 64, label: "message", normalize_length: true)

      expect(captured).to eq(described_class::MISSING_TEXT)
      expect(captured).to be_frozen
    end

    it "truncates overlong text exactly like capture" do
      source = "x" * 100

      captured = described_class.capture(source, limit: 64, label: "message", normalize_length: true)

      expect(captured).to eq(Smith::DiagnosticText.capture(source, max_bytes: 64))
      expect(captured.bytesize).to eq(64)
      expect(captured).to end_with("...[truncated]")
      expect(captured).to be_frozen
    end

    it "keeps text at the exact byte bound unchanged" do
      source = "m" * 64

      expect(described_class.capture(source, limit: 64, label: "message", normalize_length: true)).to eq(source)
    end

    it "still rejects non-text and non-UTF-8 values" do
      expect do
        described_class.capture(nil, limit: 64, label: "message", normalize_length: true)
      end.to raise_error(Smith::PersistedFailureInvalid, /message must be text/)

      expect do
        described_class.capture("failed".encode(Encoding::UTF_16LE), limit: 64, label: "message",
                                                                     normalize_length: true)
      end.to raise_error(Smith::PersistedFailureInvalid, /message is invalid/)
    end
  end
end
