# frozen_string_literal: true

require "smith/json_value"

# The strict JSON reader evals and definitions share (internal): it reads
# only what canonical JSON writes and reads back as itself, and refuses the
# same texts under every json version.
RSpec.describe "Smith::JSONValue" do
  let(:reader) { Smith.const_get(:JSONValue) }

  it "reads a number only when canonical JSON writes it and reads it back as itself" do
    %w[1e20 100000000000000000000 9007199254740992 -9007199254740992 [1,{"a":9.99e20}]].each do |text|
      expect { reader.parse!(text) }.to raise_error(ArgumentError, /2\*\*53/), text
    end
    expect { reader.parse!("[1e20]") }
      .to raise_error(ArgumentError, "canonical JSON numbers written without an exponent are at most 2**53 - 1 in size")
    expect(%w[9007199254740991 1e21 0.1 -3].map { reader.parse!(_1) }).to eq([(2**53) - 1, 1e21, 0.1, -3])
  end

  it "refuses an escaped half of a surrogate pair alone, whatever the json gem reads" do
    ['"\udc00"', '"\ud800"', '"a\ud800b"', '{"\udc00":1}', '"\ude00\ud83d"'].each do |text|
      expect { reader.parse!(text) }.to raise_error(ArgumentError, "not valid JSON"), text
    end
    expect(reader.parse!('"😀 😀"')).to eq("\u{1F600} \u{1F600}")
  end
end
