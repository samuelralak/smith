# frozen_string_literal: true

require "open3"

RSpec.describe "Smith split-step aggregate loading" do
  it "loads the prepared-step value object directly" do
    library_path = File.expand_path("../../../lib", __dir__)
    script = <<~RUBY
      require "smith/workflow/prepared_step"
      puts Smith::Workflow::PreparedStep.name
    RUBY

    stdout, stderr, status = Open3.capture3(RbConfig.ruby, "-I", library_path, "-e", script)

    expect(status).to be_success, stderr
    expect(stdout.strip).to eq("Smith::Workflow::PreparedStep")
  end

  it "loads the prepared-step recovery decision directly" do
    library_path = File.expand_path("../../../lib", __dir__)
    script = <<~RUBY
      require "smith/workflow/prepared_step_recovery"
      puts Smith::Workflow::PreparedStepRecovery.name
    RUBY

    stdout, stderr, status = Open3.capture3(RbConfig.ruby, "-I", library_path, "-e", script)

    expect(status).to be_success, stderr
    expect(stdout.strip).to eq("Smith::Workflow::PreparedStepRecovery")
  end

  it "loads the prepared-step dispatch receipt directly" do
    library_path = File.expand_path("../../../lib", __dir__)
    script = <<~RUBY
      require "smith/workflow/prepared_step_dispatch"
      puts Smith::Workflow::PreparedStepDispatch.name
    RUBY

    stdout, stderr, status = Open3.capture3(RbConfig.ruby, "-I", library_path, "-e", script)

    expect(status).to be_success, stderr
    expect(stdout.strip).to eq("Smith::Workflow::PreparedStepDispatch")
  end

  it "loads its internal dependencies when required directly" do
    library_path = File.expand_path("../../../lib", __dir__)
    script = <<~RUBY
      require "smith/workflow/split_step_persistence"
      puts Smith::Workflow::SplitStepPersistence.name
    RUBY

    stdout, stderr, status = Open3.capture3(RbConfig.ruby, "-I", library_path, "-e", script)

    expect(status).to be_success, stderr
    expect(stdout.strip).to eq("Smith::Workflow::SplitStepPersistence")
  end
end
