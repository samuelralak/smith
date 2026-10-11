# frozen_string_literal: true

require "smith/doctor"

RSpec.describe Smith::Doctor::Checks::Artifacts do
  around do |example|
    names = %i[artifact_store artifact_options test_mode persistence_adapter]
    settings = names.to_h { [_1, Smith.config.public_send(_1)] }
    example.run
  ensure
    Smith.configure { |config| settings.each { |name, value| config.public_send(:"#{name}=", value) } }
  end

  def results(**settings)
    Smith.configure { |config| settings.each { |name, value| config.public_send(:"#{name}=", value) } }
    report = Smith::Doctor::Report.new
    described_class.run(report)
    report.checks.map { [_1.name, _1.status] }
  end

  it "warns when no store is configured, fails when it cannot be built, and passes a durable one" do
    expect(results(artifact_store: nil, test_mode: false)).to eq([["artifacts.store", :warn]])
    expect(results(artifact_store: :dropbox)).to eq([["artifacts.store", :fail]])
    expect(results(artifact_store: :s3, artifact_options: { bucket: "b", client: Object.new }))
      .to eq([["artifacts.store", :pass]])
  end

  it "warns of a process-local store beside persisted state, and of a store that cannot vouch for refs" do
    expect(results(artifact_store: :memory, persistence_adapter: :memory))
      .to eq([["artifacts.store", :pass], ["artifacts.durability", :warn]])
    unvouched = Class.new do
      def store(*, **) = "ref"
      def fetch(_ref) = nil
      def expired(**) = []
    end
    expect(results(artifact_store: unvouched.new, persistence_adapter: nil))
      .to eq([["artifacts.store", :pass], ["artifacts.ownership", :warn]])
  end
end
