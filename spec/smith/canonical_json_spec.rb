# frozen_string_literal: true

require "json"
require "smith/canonical_json"

RSpec.describe Smith::CanonicalJSON do
  reference = JSON.parse(File.read(File.expand_path("../fixtures/canonical_json_reference.json", __dir__)))
  float = ->(hex) { [hex].pack("H*").unpack1("G") }

  def generate(value) = described_class.generate(value)

  it "matches every number of RFC 8785's Appendix B as Node.js writes it" do
    expect(reference["numbers"].size).to eq(24)
    reference["numbers"].each do |row|
      expect(generate(float.call(row["ieee754_hex"]))).to eq(row["canonical"]), row["ieee754_hex"]
    end
  end

  it "refuses NaN and Infinity" do
    reference["rejected"].each do |row|
      expect { generate(float.call(row["ieee754_hex"])) }.to raise_error(described_class::Error, /finite/)
    end
    expect { generate(-Float::INFINITY) }.to raise_error(described_class::Error)
  end

  it "orders members by their keys' UTF-16 code units, as the RFC's sorting example" do
    example = reference["sort_example"]
    values = JSON.parse(example["canonical"])
    keys = example["input_keys_utf16_hex"].map { |hex| [hex].pack("H*").force_encoding(Encoding::UTF_16BE).encode("UTF-8") }
    expect(generate(keys.to_h { |key| [key, values.fetch(key)] })).to eq(example["canonical"])
    expect(generate(keys.reverse.to_h { |key| [key, values.fetch(key)] })).to eq(example["canonical"])
  end

  it "writes the RFC's full example" do
    example = reference["full_example"]
    expect(generate(JSON.parse(example["input_text"]))).to eq(example["canonical"])
  end

  it "writes every control character as JSON.stringify does, and leaves the rest as it is" do
    short = { 0x08 => "\\b", 0x09 => "\\t", 0x0a => "\\n", 0x0c => "\\f", 0x0d => "\\r" }
    (0x00..0x1f).each do |code|
      expect(generate(code.chr)).to eq(%("#{short.fetch(code) { format("\\u%04x", code) }}"))
    end
    expect(generate("\"\\")).to eq('"\\"\\\\"')
    expect(generate("/\u007f é\u{1f600}")).to eq("\"/\u007f é\u{1f600}\"")
  end

  it "writes literals, integers, symbols and nested values without whitespace" do
    expect(generate([nil, true, false, -0.0, 12.0, 12, -7, :name, { b: [1], a: { c: "x" } }]))
      .to eq('[null,true,false,0,12,12,-7,"name",{"a":{"c":"x"},"b":[1]}]')
    expect(generate((2**53) - 1)).to eq("9007199254740991")
    expect(generate(-(2**53) + 1)).to eq("-9007199254740991")
  end

  it "returns UTF-8 text, and takes an ASCII-only string in any encoding" do
    expect(generate({ "k" => "v".b }).encoding).to eq(Encoding::UTF_8)
    expect(generate("plain".encode(Encoding::US_ASCII))).to eq('"plain"')
  end

  it "refuses keys that are equal once converted, integers past 2**53 - 1, and values JSON cannot hold" do
    expect { generate({ a: 1, "a" => 2 }) }.to raise_error(described_class::Error, /twice/)
    expect { generate(2**53) }.to raise_error(described_class::Error, /2\*\*53/)
    expect { generate(-(2**53)) }.to raise_error(described_class::Error)
    expect { generate(Rational(1, 2)) }.to raise_error(described_class::Error, /Rational/)
    expect { generate(Object.new) }.to raise_error(described_class::Error)
    expect { generate({ 1 => "x" }) }.to raise_error(described_class::Error, /keys/)
  end

  it "refuses strings that are not valid UTF-8, as values and as keys" do
    expect { generate("\xff") }.to raise_error(described_class::Error, /UTF-8/)
    expect { generate("caf\xe9".b) }.to raise_error(described_class::Error, /UTF-8/)
    expect { generate({ "\xff" => 1 }) }.to raise_error(described_class::Error, /UTF-8/)
    expect { generate("é".encode(Encoding::ISO_8859_1)) }.to raise_error(described_class::Error, /UTF-8/)
  end

  it "nests at most 64 deep" do
    deep = ->(levels) { (1...levels).reduce([]) { |inner, _| [inner] } }
    expect(generate(deep.call(64))).to eq("#{"[" * 64}#{"]" * 64}")
    expect { generate(deep.call(65)) }.to raise_error(described_class::Error, /64/)
    cycle = []
    cycle << cycle
    expect { generate(cycle) }.to raise_error(described_class::Error, /64/)
  end

  it "holds at most 1,000,000 values" do
    expect(generate(Array.new(999_999, 0)).bytesize).to eq(1 + (999_999 * 2))
    expect { generate(Array.new(1_000_000, 0)) }.to raise_error(described_class::Error, /1000000 values/)
  end

  it "writes at most 64 MiB" do
    limit = 64 * 1024 * 1024
    expect(generate("a" * (limit - 2)).bytesize).to eq(limit)
    expect { generate("a" * (limit - 1)) }.to raise_error(described_class::Error, /bytes/)
  end
end
