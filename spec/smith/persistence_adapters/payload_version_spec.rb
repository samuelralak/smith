# frozen_string_literal: true

RSpec.describe Smith::PersistenceAdapters::PayloadVersion do
  describe ".call" do
    it "reads a non-negative integer from serialized JSON or a decoded document" do
      expect(described_class.call('{"persistence_version":7}')).to eq(7)
      expect(described_class.call("persistence_version" => 8)).to eq(8)
    end

    it "treats missing and syntactically malformed versions as version zero" do
      payloads = ["not-json", {}]

      expect(payloads.map { |payload| described_class.call(payload) }).to all(eq(0))
    end

    it "rejects valid JSON payloads that are not objects" do
      ["null", "[]", '"legacy"'].each do |payload|
        expect { described_class.call(payload) }.to raise_error(TypeError, /payload must be a JSON object/)
      end
    end

    it "rejects explicit invalid versions" do
      [nil, -1, "1", 1.5].each do |version|
        expect do
          described_class.call("persistence_version" => version)
        end.to raise_error(TypeError, /persistence_version must be a non-negative integer/)
      end
    end
  end
end
