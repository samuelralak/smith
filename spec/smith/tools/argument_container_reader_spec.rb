# frozen_string_literal: true

RSpec.describe Smith::Tool::ArgumentContainerReader do
  subject(:reader) do
    described_class.new(
      scalar_snapshot: instance_double(Smith::Tool::ArgumentScalarSnapshot),
      byte_count: -> { 0 }
    )
  end

  it "owns one native Array snapshot before allocation admission" do
    source = Class.new(Array) do
      def initialize_copy(*) = raise("overridden copy must not run")
    end.new(["admitted"])

    snapshot = reader.snapshot(source, :array)
    source.concat(Array.new(10_000, "late"))

    expect(reader.size(snapshot, :array)).to eq(1)
    expect(snapshot).to eq(["admitted"])
    expect(snapshot).to be_frozen
  end

  it "owns one native Hash snapshot before allocation admission" do
    source = Class.new(Hash) do
      def initialize_copy(*) = raise("overridden copy must not run")
    end.new
    Hash.instance_method(:[]=).bind_call(source, "admitted", true)

    snapshot = reader.snapshot(source, :hash)
    10_000.times { |index| source[index] = true }

    expect(reader.size(snapshot, :hash)).to eq(1)
    expect(snapshot).to eq("admitted" => true)
    expect(snapshot).to be_frozen
  end
end
