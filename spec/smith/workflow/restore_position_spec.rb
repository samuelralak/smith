# frozen_string_literal: true

require "json"

RSpec.describe "Smith::Workflow restore of an unknown position" do
  let(:workflow_class) { require_const("Smith::Workflow") }

  def json_round_trip(workflow)
    JSON.parse(JSON.generate(workflow.to_state))
  end

  def two_step_workflow(name)
    with_stubbed_class(name, workflow_class) do
      initial_state :idle

      transition :prepare, from: :idle, to: :prepared do
        compute { |_step| nil }
      end

      transition :finish, from: :prepared, to: :done do
        compute { |_step| nil }
      end
    end
  end

  it "restores a state named only by a transition's from: or to:" do
    klass = two_step_workflow("SpecRestoreImplicitStateWorkflow")
    workflow = klass.new
    workflow.advance!

    restored = klass.from_state(json_round_trip(workflow))

    expect(restored.state).to eq(:prepared)
    expect(restored.run!.state).to eq(:done)
  end

  it "refuses a state the class no longer knows instead of ending the run" do
    klass = two_step_workflow("SpecRestoreUnknownStateWorkflow")
    payload = json_round_trip(klass.new).merge("state" => "renamed_away", "persistence_key" => "run-1")

    expect { klass.from_state(payload) }.to raise_error(Smith::UnknownStateOnRestore) do |error|
      expect(error.state).to eq(:renamed_away)
      expect(error.persistence_key).to eq("run-1")
      expect(error.workflow).to eq("SpecRestoreUnknownStateWorkflow")
      expect(error.message).to include("migrate_from")
    end
  end

  it "refuses a pending transition the class no longer declares" do
    klass = two_step_workflow("SpecRestoreUnknownTransitionWorkflow")
    payload = json_round_trip(klass.new).merge("next_transition_name" => "removed_step")

    expect { klass.from_state(payload) }.to raise_error(Smith::UnknownTransitionOnRestore) do |error|
      expect(error.transition).to eq(:removed_step)
    end
  end

  it "restores a pending transition the class declares" do
    klass = two_step_workflow("SpecRestoreKnownTransitionWorkflow")
    payload = json_round_trip(klass.new).merge("next_transition_name" => "prepare")

    expect(klass.from_state(payload).pending_transition_name).to eq(:prepare)
  end

  it "lets migrate_from map an old state name before the check" do
    klass = with_stubbed_class("SpecRestoreMigratedStateWorkflow", workflow_class) do
      initial_state :idle
      persistence_schema_version 2

      migrate_from(1) do |payload|
        payload[:state] = "drafted" if payload[:state] == "draft_ready"
        payload
      end

      transition :draft, from: :idle, to: :drafted do
        compute { |_step| nil }
      end

      transition :finish, from: :drafted, to: :done do
        compute { |_step| nil }
      end
    end
    payload = json_round_trip(klass.new).merge("state" => "draft_ready", "schema_version" => 1)

    restored = klass.from_state(payload)

    expect(restored.state).to eq(:drafted)
    expect(restored.run!.state).to eq(:done)
  end

  it "classifies both refusals as non-retryable Smith errors" do
    expect(Smith::UnknownStateOnRestore.ancestors).to include(Smith::Error)
    expect(Smith::UnknownTransitionOnRestore.ancestors).to include(Smith::Error)
    error = Smith::UnknownStateOnRestore.new(workflow: "W", persistence_key: "k", state: :gone)
    expect(Smith::Errors.retryable?(error)).to be(false)
  end
end
