# frozen_string_literal: true

RSpec.describe Smith::ToolCaptureFailed do
  it "reconstructs exact JSON details without interning untrusted values" do
    error = described_class.from_details(
      "tool_name" => "catalog_search",
      "reason" => "collector_failed"
    )

    expect(error.tool_name).to eq("catalog_search")
    expect(error.reason).to eq(:collector_failed)
  end

  it "rejects unknown, duplicate, and missing persisted attributes" do
    expect do
      described_class.from_details(tool_name: "search", reason: "collector_failed", extra: true)
    end.to raise_error(ArgumentError, /unknown attribute/)

    expect do
      described_class.from_details("tool_name" => "search", tool_name: "search", reason: "collector_failed")
    end.to raise_error(ArgumentError, /duplicate attribute/)

    expect do
      described_class.from_details(tool_name: "search")
    end.to raise_error(ArgumentError, /missing required attributes/)
  end

  it "rejects unrecognized reasons and unbounded tool names" do
    expect do
      described_class.from_details(tool_name: "search", reason: "future_reason")
    end.to raise_error(ArgumentError, /reason is not recognized/)

    expect do
      described_class.from_details(tool_name: "x" * 257, reason: "collector_failed")
    end.to raise_error(ArgumentError, /bounded non-empty/)
  end

  it "uses a stable diagnostic name for an anonymous strict-capture tool" do
    tool = Class.new(Smith::Tool) do
      capture_result(strict: true) { |_kwargs, result| result }
      def perform = :value
    end.new

    expect { tool.execute }.to raise_error(described_class) do |error|
      expect(error.tool_name).to eq("anonymous_tool")
      expect(error.reason).to eq(:collector_missing)
    end
  end

  it "keeps invalid runtime tool identities inside the typed failure boundary" do
    invalid_names = ["x" * 257, "\xFF".b, "\xFF".dup.force_encoding(Encoding::UTF_8)]

    invalid_names.each do |invalid_name|
      tool = Class.new(Smith::Tool) do
        capture_result(strict: true) { |_kwargs, result| result }
        def perform = :value
      end.new
      tool.define_singleton_method(:name) { invalid_name }

      expect { tool.execute }.to raise_error(described_class) do |error|
        expect(error.tool_name).to match(/\Atool_[0-9a-f]{64}\z/)
        expect(error.reason).to eq(:collector_missing)
        expect { JSON.generate(error.details) }.not_to raise_error
      end
    end
  end

  it "rejects persisted tool names that are not valid UTF-8" do
    ["\xFF".b, "\xFF".dup.force_encoding(Encoding::UTF_8)].each do |invalid_name|
      expect do
        described_class.from_details(tool_name: invalid_name, reason: "collector_failed")
      end.to raise_error(ArgumentError, /valid UTF-8/)
    end
  end
end
