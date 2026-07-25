# frozen_string_literal: true

RSpec.describe Smith::Tool::InvocationRequest do
  let(:invocation) do
    Smith::Tool::Invocation.new(
      tool_call_id: "call-1",
      tool_name: "search",
      ordinal: 1,
      batch_ordinal: 1,
      batch_size: 1
    )
  end

  let(:tool_class) do
    Class.new(Smith::Tool) do
      def perform(**) = nil
    end
  end

  it "owns and freezes provider arguments at the Smith host boundary" do
    arguments = { "query" => "Ruby", "filters" => [{ "kind" => "primary" }] }
    request = described_class.new(
      invocation: Smith::Tool::Invocation.new(
        tool_call_id: "call-1",
        tool_name: "search",
        ordinal: 1,
        batch_ordinal: 1,
        batch_size: 1
      ),
      tool_class:,
      arguments:
    )
    arguments.fetch("filters").first["kind"] = "changed"

    expect(request.arguments).to eq("query" => "Ruby", "filters" => [{ "kind" => "primary" }])
    expect(request.arguments).to be_frozen
    expect(request.arguments.fetch("filters")).to be_frozen
    expect(request.arguments.fetch("filters").first).to be_frozen
  end

  it "rejects non-Smith tool classes" do
    expect do
      described_class.new(
        invocation: Smith::Tool::Invocation.new(
          tool_call_id: "call-1",
          tool_name: "search",
          ordinal: 1,
          batch_ordinal: 1,
          batch_size: 1
        ),
        tool_class: String,
        arguments: {}
      )
    end.to raise_error(Dry::Struct::Error)
  end

  it "rejects excessive argument nesting without recursive stack growth" do
    arguments = {}
    (described_class::MAX_ARGUMENT_DEPTH + 1).times { arguments = { next: arguments } }

    expect do
      described_class.new(invocation:, tool_class:, arguments:)
    end.to raise_error(Smith::Error, /tool arguments exceed .* levels/)
  end

  it "rejects duplicate string-equivalent keys at every nesting level" do
    arguments = { "filters" => [{ "kind" => "primary", kind: "secondary" }] }

    expect do
      described_class.new(invocation:, tool_class:, arguments:)
    end.to raise_error(Smith::Error, "tool arguments contain duplicate canonical Hash keys")
  end

  it "rejects cyclic argument graphs without recursive stack growth" do
    arguments = {}
    arguments["self"] = arguments

    expect do
      described_class.new(invocation:, tool_class:, arguments:)
    end.to raise_error(Smith::Error, "tool arguments contain a cyclic value")
  end

  it "preserves shared container identity without duplicating the argument graph" do
    shared = [{ "source" => "primary" }]
    request = described_class.new(
      invocation:,
      tool_class:,
      arguments: { "first" => shared, "second" => shared }
    )

    expect(request.arguments.fetch("first")).to equal(request.arguments.fetch("second"))
    expect(request.argument_node_count).to eq(7)
    expect(request.argument_byte_count).to eq(37)
  end

  it "rejects argument payloads over the byte limit" do
    arguments = { "value" => "x" * described_class::MAX_ARGUMENT_BYTES }

    expect do
      described_class.new(invocation:, tool_class:, arguments:)
    end.to raise_error(Smith::Error, /tool arguments exceed .* bytes/)
  end

  it "rejects argument graphs over the value limit" do
    arguments = { "values" => Array.new(described_class::MAX_ARGUMENT_NODES) }

    expect do
      described_class.new(invocation:, tool_class:, arguments:)
    end.to raise_error(Smith::Error, /tool arguments exceed .* values/)
  end

  it "uses native container size instead of hostile overrides" do
    array = Class.new(Array) do
      define_method(:length) { Smith::Tool::InvocationRequest::MAX_ARGUMENT_NODES }
      define_method(:[]) { |_index| raise "overridden child access must not run" }
    end.new(["visible"])

    request = described_class.new(invocation:, tool_class:, arguments: { "values" => array })

    expect(request.arguments).to eq("values" => ["visible"])
  end

  it "uses native Hash traversal instead of hostile overrides" do
    hash = Class.new(Hash) do
      def length = 0
      def keys = []
      def fetch(*) = raise("overridden fetch must not run")
      def each_pair = self
    end.new
    Hash.instance_method(:[]=).bind_call(hash, "visible", "kept")

    request = described_class.new(invocation:, tool_class:, arguments: hash)

    expect(request.arguments).to eq("visible" => "kept")
  end

  it "rejects non-Hash values that masquerade as argument objects" do
    masquerader = Object.new
    masquerader.define_singleton_method(:is_a?) do |klass|
      klass == Hash || Object.instance_method(:is_a?).bind_call(self, klass)
    end

    expect do
      described_class.new(invocation:, tool_class:, arguments: masquerader)
    end.to raise_error(Smith::Error, "tool arguments must contain JSON-compatible values")
  end

  it "accounts for the expanded serialized size of shared containers" do
    shared = { "payload" => "x" * 128 }
    arguments = { "copies" => Array.new(9_000, shared) }

    expect do
      described_class.new(invocation:, tool_class:, arguments:)
    end.to raise_error(Smith::Error, /tool arguments exceed .* bytes/)
  end

  it "rejects non-finite numeric arguments" do
    [Float::INFINITY, -Float::INFINITY, Float::NAN].each do |value|
      expect do
        described_class.new(invocation:, tool_class:, arguments: { "value" => value })
      end.to raise_error(Smith::Error, "tool arguments must contain finite numbers")
    end
  end

  it "counts integer payload bytes" do
    request = described_class.new(
      invocation:,
      tool_class:,
      arguments: { "value" => 123_456_789 }
    )

    expect(request.argument_byte_count).to eq("value".bytesize + "123456789".bytesize)
  end

  it "rejects scalar symbols as non-JSON values" do
    expect do
      described_class.new(invocation:, tool_class:, arguments: { "value" => :primary })
    end.to raise_error(Smith::Error, "tool arguments must contain JSON-compatible values")
  end

  it "rejects strings that cannot be encoded as UTF-8" do
    invalid = "\xFF".b

    expect do
      described_class.new(invocation:, tool_class:, arguments: { "value" => invalid })
    end.to raise_error(Smith::Error, "tool arguments must contain valid UTF-8 strings")
  end

  it "rejects malformed strings already tagged as UTF-8" do
    invalid = "\xFF".b.force_encoding(Encoding::UTF_8)

    expect do
      described_class.new(invocation:, tool_class:, arguments: { "value" => invalid })
    end.to raise_error(Smith::Error, "tool arguments must contain valid UTF-8 strings")
  end

  it "measures String subclasses through core String operations" do
    hostile_string = Class.new(String) do
      def bytesize = 5
      def encode(*) = self
      def valid_encoding? = true
    end.new("x" * (described_class::MAX_ARGUMENT_BYTES + 1))

    expect do
      described_class.new(invocation:, tool_class:, arguments: { "value" => hostile_string })
    end.to raise_error(Smith::Error, /tool arguments exceed .* bytes/)
  end

  it "rejects integers that cannot fit before decimal rendering" do
    oversized_integer = 1 << (described_class::MAX_ARGUMENT_BYTES * 4)

    expect do
      described_class.new(invocation:, tool_class:, arguments: { "value" => oversized_integer })
    end.to raise_error(Smith::Error, /tool arguments exceed .* bytes/)
  end

  it "normalizes unsupported encoding converters to Smith errors" do
    unsupported = "value".dup.force_encoding(Encoding.find("UTF-7"))

    expect do
      described_class.new(invocation:, tool_class:, arguments: { "value" => unsupported })
    end.to raise_error(Smith::Error, "tool arguments must contain valid UTF-8 strings")
  end

  it "normalizes valid transcoded strings to owned UTF-8 values" do
    source = "\xE9".b.force_encoding(Encoding::ISO_8859_1)
    request = described_class.new(invocation:, tool_class:, arguments: { "value" => source })

    expect(request.arguments.fetch("value")).to eq("é")
    expect(request.arguments.fetch("value").encoding).to eq(Encoding::UTF_8)
    expect(request.arguments.fetch("value")).to be_frozen
  end
end
