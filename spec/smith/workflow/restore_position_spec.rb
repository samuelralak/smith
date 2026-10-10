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

  it "classifies both refusals as Smith errors that are neither retryable nor retry-forbidden" do
    errors = [
      Smith::UnknownStateOnRestore.new(workflow: "W", persistence_key: "k", state: :gone),
      Smith::UnknownTransitionOnRestore.new(workflow: "W", persistence_key: "k", transition: :gone)
    ]

    errors.each do |error|
      expect(error).to be_a(Smith::Error)
      expect(error).not_to be_a(Smith::WorkflowError)
      expect(Smith::Errors.retryable?(error)).to be(false)
      expect(Smith::Errors.retry_forbidden?(error)).to be(false)
    end
  end

  it "bounds the persistence key it reports" do
    error = Smith::UnknownStateOnRestore.new(workflow: "W", persistence_key: "k" * 100_000, state: :gone)

    expect(error.message.bytesize).to be < 2_000
    expect(error.message).to include("bump persistence_schema_version")
  end

  it "restores String-named states, mid-run and terminal" do
    klass = with_stubbed_class("SpecRestoreStringStatesWorkflow", workflow_class) do
      initial_state "idle"

      transition("prepare", from: "idle", to: "prepared") { compute { |_step| nil } }
      transition("finish", from: "prepared", to: "finished") { compute { |_step| nil } }
    end
    workflow = klass.new
    workflow.advance!

    mid = klass.from_state(json_round_trip(workflow))
    expect(mid.state).to eq("prepared")
    finished = mid.run!
    expect(finished.state).to eq("finished")
    expect(klass.from_state(json_round_trip(mid)).state).to eq("finished")
  end

  it "knows a state named only by a transition's from:" do
    klass = with_stubbed_class("SpecRestoreFromOnlyWorkflow", workflow_class) do
      initial_state :idle

      transition(:start, from: :idle, to: :done) { compute { |_step| nil } }
      transition(:side_exit, from: :side, to: :done) { compute { |_step| nil } }
    end
    payload = json_round_trip(klass.new).merge("state" => "side")

    restored = klass.from_state(payload)

    expect(restored.state).to eq(:side)
    expect(restored.run!.state).to eq(:done)
  end

  it "knows a state named only by a transition's to:" do
    klass = two_step_workflow("SpecRestoreToOnlyWorkflow")
    payload = json_round_trip(klass.new).merge("state" => "done")

    expect(klass.from_state(payload).state).to eq(:done)
  end

  it "refuses a payload with no state when the class has an initial state" do
    klass = with_stubbed_class("SpecRestoreNilStateWorkflow", workflow_class) do
      initial_state :idle
      state :failed

      transition(:go, from: :idle, to: :done) { compute { |_step| nil } }
    end
    payload = json_round_trip(klass.new)

    [payload.merge("state" => nil), payload.except("state")].each do |broken|
      expect { klass.from_state(broken) }.to raise_error(Smith::UnknownStateOnRestore)
    end
  end

  it "reports a definition digest mismatch before an unknown state" do
    original = with_stubbed_class("SpecRestoreDigestV1Workflow", workflow_class) do
      definition_digest "a" * 64
      initial_state :idle

      transition(:go, from: :idle, to: :mid) { compute { |_step| nil } }
      transition(:finish, from: :mid, to: :done) { compute { |_step| nil } }
    end
    current = with_stubbed_class("SpecRestoreDigestV2Workflow", workflow_class) do
      definition_digest "b" * 64
      initial_state :idle

      transition(:finish, from: :idle, to: :done) { compute { |_step| nil } }
    end
    workflow = original.new
    workflow.advance!

    expect { current.from_state(json_round_trip(workflow)) }
      .to raise_error(Smith::WorkflowError, /definition does not match/)
  end

  it "still refuses when migrate_from is declared without bumping the schema version" do
    klass = with_stubbed_class("SpecRestoreNoBumpWorkflow", workflow_class) do
      initial_state :idle

      migrate_from(1) do |payload|
        payload[:state] = "drafted"
        payload
      end

      transition(:draft, from: :idle, to: :drafted) { compute { |_step| nil } }
    end
    payload = json_round_trip(klass.new).merge("state" => "draft_ready")

    expect { klass.from_state(payload) }
      .to raise_error(Smith::UnknownStateOnRestore, /bump persistence_schema_version/)
  end

  it "reports a stored run in an unknown state as stuck, not terminal" do
    adapter = Smith::PersistenceAdapters::Memory.new
    klass = two_step_workflow("SpecRestoreStuckWorkflow")
    stale = json_round_trip(klass.new).merge(
      "state" => "renamed_away", "updated_at" => "2026-01-01T00:00:00Z", "class" => "SpecRestoreStuckWorkflow"
    )
    adapter.store("stuck-1", JSON.generate(stale))

    expect(klass.stuck_for?(persistence_key: "stuck-1", threshold: 60, adapter:)).to be(true)
  end
end
