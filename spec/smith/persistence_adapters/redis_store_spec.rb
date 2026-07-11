# frozen_string_literal: true

RSpec.describe Smith::PersistenceAdapters::RedisStore do
  it "does not recreate missing state from a nonzero expected version" do
    client = Class.new do
      def watch(_key)
        yield
      end

      def get(_key) = nil

      def multi
        raise "missing-version rejection must happen before MULTI"
      end
    end.new
    adapter = described_class.new(redis: client)

    expect do
      adapter.store_versioned(
        "missing",
        JSON.generate(persistence_version: 3),
        expected_version: 2
      )
    end.to raise_error(Smith::PersistenceVersionConflict) { |error|
      expect(error.expected).to eq(2)
      expect(error.actual).to eq(:missing)
    }
  end
end
