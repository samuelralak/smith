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

  it "warns of a process-local store beside durable state, and of a store that cannot vouch for refs" do
    expect(results(artifact_store: :memory, persistence_adapter: :redis))
      .to eq([["artifacts.store", :pass], ["artifacts.durability", :warn]])
    expect(results(artifact_store: :memory, persistence_adapter: :memory)).to eq([["artifacts.store", :pass]])
    expect(results(artifact_store: :memory, persistence_adapter: nil)).to eq([["artifacts.store", :pass]])
    expect(results(artifact_store: nil, test_mode: true)).to eq([["artifacts.store", :pass]])
    unvouched = Class.new do
      def store(*, **) = "ref"
      def fetch(_ref) = nil
      def expired(**) = []
    end
    expect(results(artifact_store: unvouched.new, persistence_adapter: nil))
      .to eq([["artifacts.store", :pass], ["artifacts.ownership", :warn]])
  end

  it "warns of a table, directory or bucket the store cannot use", :ar do
    expect(results(artifact_store: :active_record, artifact_options: { model: "SmithArtifactRecord" }))
      .to eq([["artifacts.store", :pass]])
    expect(results(artifact_store: :active_record, artifact_options: { model: "SmithWorkflowStateRecord" }))
      .to eq([["artifacts.store", :pass], ["artifacts.usable", :warn]])
    expect(results(artifact_store: :active_record, artifact_options: { model: "NoSuchArtifactModel" }))
      .to eq([["artifacts.store", :pass], ["artifacts.usable", :warn]])
    expect(results(artifact_store: :file, artifact_options: { dir: "/nonexistent/smith" }))
      .to eq([["artifacts.store", :pass], ["artifacts.usable", :warn]])
    unreachable = Object.new
    unreachable.define_singleton_method(:head_bucket) { |**| raise Timeout::Error }
    expect(results(artifact_store: :s3, artifact_options: { bucket: "b", client: unreachable }))
      .to eq([["artifacts.store", :pass], ["artifacts.usable", :warn]])
  end

  it "runs as part of smith doctor, and a missing store is a workflow error" do
    Smith.configure { |config| config.artifact_store = :memory }
    report = Smith::Doctor.run(io: StringIO.new)

    expect(report.checks.map(&:name)).to include("artifacts.store")
    expect(report.checks.map(&:name)).not_to include("config.artifact_store")
    expect(Smith::ArtifactStoreMissing.ancestors).to include(Smith::WorkflowError)
  end
end
