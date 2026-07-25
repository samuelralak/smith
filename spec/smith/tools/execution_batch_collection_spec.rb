# frozen_string_literal: true

RSpec.describe Smith::Tool::ExecutionBatchCollection do
  it "captures coherent membership without invoking overridden protocol checks" do
    source = {}
    replacement_a = Data.define(:name, :arguments).new(:replacement_a, {})
    replacement_b = Data.define(:name, :arguments).new(:replacement_b, {})
    original_b = Data.define(:name, :arguments).new(:original_b, {})
    original_a = Class.new do
      define_method(:initialize) { |collection| @collection = collection }
      define_method(:respond_to?) do |name, *args|
        @collection.replace(a: replacement_a, b: replacement_b)
        super(name, *args)
      end
      def name = :original_a
      def arguments = {}
    end.new(source)
    source.replace(a: original_a, b: original_b)

    captured = described_class.capture(source)

    expect(captured.values).to eq([original_a, original_b])
    expect(source.values).to eq([original_a, original_b])
  end
end
