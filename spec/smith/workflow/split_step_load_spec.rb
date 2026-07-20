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

  it "loads the prepared-step execution contracts directly" do
    library_path = File.expand_path("../../../lib", __dir__)
    script = <<~RUBY
      require "smith/workflow/prepared_step_execution_authorization"
      require "smith/workflow/prepared_step_execution_result"
      snapshot = Smith::Workflow::SplitStepPersistence::ExecutionBindingSnapshot.capture(
        nil,
        workflow_class: Smith::Workflow
      )
      begin
        snapshot.fetch!(:missing, workflow_class: Smith::Workflow, transition_name: :missing, role: :agent)
      rescue Smith::WorkflowError
        puts "workflow error loaded"
      end
      puts Smith::Workflow::PreparedStepExecutionAuthorization.name
      puts Smith::Workflow::PreparedStepExecutionResult.name
    RUBY

    stdout, stderr, status = Open3.capture3(RbConfig.ruby, "-I", library_path, "-e", script)

    expect(status).to be_success, stderr
    expect(stdout.lines.map(&:strip)).to eq(
      [
        "workflow error loaded",
        "Smith::Workflow::PreparedStepExecutionAuthorization",
        "Smith::Workflow::PreparedStepExecutionResult"
      ]
    )
  end

  it "loads the composite transport contracts directly" do
    library_path = File.expand_path("../../../lib", __dir__)
    script = <<~RUBY
      require "smith/workflow/composite/branch"
      require "smith/workflow/composite/input"
      require "smith/workflow/composite/effects"
      require "smith/workflow/composite/branch_outcome"
      require "smith/workflow/composite/plan"
      require "smith/workflow/composite/branch_failure"
      require "securerandom"
      prepared_step = Smith::Workflow::PreparedStep.new(
        token: SecureRandom.uuid,
        transition: "finish",
        from: "idle",
        persistence_key: "direct-load",
        persistence_version: 1,
        step_number: 1,
        preparation_digest: "a" * 64,
        definition_digest: "b" * 64
      )
      dispatch = Smith::Workflow::PreparedStepDispatch.new(
        prepared_step:,
        token: SecureRandom.uuid,
        dispatch_digest: "c" * 64
      )
      input = Smith::Workflow::Composite::Input.build(agent_messages: [], session_messages: [])
      branch = Smith::Workflow::Composite::Branch.build(
        ordinal: 0,
        key: "0",
        agent: "worker",
        binding_identity: "e" * 64,
        budget: {}
      )
      plan = Smith::Workflow::Composite::Plan.build(
        dispatch:,
        kind: :parallel,
        transition: "finish",
        from: "idle",
        execution_namespace: SecureRandom.uuid,
        branches: [branch],
        input_digest: input.digest,
        budget_state_digest: "d" * 64
      )
      failure = Smith::Workflow::Composite::BranchFailure.new(
        branch_key: "0",
        error: Smith::Workflow::Composite::Error.new(
          class_name: "RuntimeError", family: "other", retryable: false, kind: nil
        )
      )
      puts Smith::Workflow::Composite::Branch.name
      puts Smith::Workflow::Composite::Input.name
      puts Smith::Workflow::Composite::Effects.name
      puts Smith::Workflow::Composite::BranchOutcome.name
      puts Smith::Workflow::Composite::Plan.name
      puts Smith::Workflow::Composite::BranchFailure.name
      puts Smith::EXECUTION_SEMANTICS_VERSION
      puts Smith::Workflow::Composite::Plan.deserialize(plan.serialize).branches.length
      puts failure.branch_key
    RUBY

    stdout, stderr, status = Open3.capture3(RbConfig.ruby, "-I", library_path, "-e", script)

    expect(status).to be_success, stderr
    expect(stdout.lines.map(&:strip)).to eq(
      %w[
        Smith::Workflow::Composite::Branch
        Smith::Workflow::Composite::Input
        Smith::Workflow::Composite::Effects
        Smith::Workflow::Composite::BranchOutcome
        Smith::Workflow::Composite::Plan
        Smith::Workflow::Composite::BranchFailure
        3
        1
        0
      ]
    )
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
