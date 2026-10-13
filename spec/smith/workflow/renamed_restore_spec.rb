# frozen_string_literal: true

require "json"

RSpec.describe "Smith::Workflow restore across renamed states and transitions" do
  let(:workflow_class) { require_const("Smith::Workflow") }
  let(:adapter) { Smith::PersistenceAdapters::Memory.new }

  def json_round_trip(workflow)
    JSON.parse(JSON.generate(workflow.to_state))
  end

  # Version 1: idle -(prepare)-> prepared -(finish)-> done.
  def first_version(name)
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

  # Version 2 renames the state :prepared to :ready and the transition :finish to :complete.
  def second_version(name, &extra)
    with_stubbed_class(name, workflow_class) do
      initial_state :idle
      renamed_state :prepared, to: :ready
      renamed_transition :finish, to: :complete

      transition :prepare, from: :idle, to: :ready do
        compute { |_step| nil }
      end

      transition :complete, from: :ready, to: :done do
        compute { |_step| nil }
      end

      class_eval(&extra) if extra
    end
  end

  # A run of the first version, persisted after its first step, as the second version restores it.
  def persisted_after_prepare
    workflow = first_version("SpecRenameFirstWorkflow").new
    workflow.advance!
    json_round_trip(workflow)
  end

  it "restores a run in a renamed state, and it carries on under the new names to the end" do
    payload = persisted_after_prepare
    renamed = second_version("SpecRenameSecondWorkflow")

    restored = renamed.from_state(payload)

    expect(restored.state).to eq(:ready)
    expect(restored.run!.state).to eq(:done)
  end

  it "restores the transition a run takes next under its new name, kept the type it was persisted as" do
    renamed = second_version("SpecRenameNextWorkflow")
    payload = persisted_after_prepare.merge("next_transition_name" => "finish")

    expect(renamed.from_state(payload).pending_transition_name).to eq(:complete)
  end

  it "maps the names of the last failed step too" do
    renamed = second_version("SpecRenameFailedStepWorkflow")
    payload = persisted_after_prepare.merge(
      "last_failed_step" => { "transition" => "finish", "from" => "prepared", "to" => "done", "error_kind" => "boom" }
    )

    expect(renamed.allocate.send(:apply_renames, payload.transform_keys(&:to_sym))[:last_failed_step])
      .to include("transition" => "complete", "from" => "ready", "to" => "done")
  end

  it "resumes a run waiting in a renamed transition, under the wait's own token" do
    first = with_stubbed_class("SpecRenameWaitFirstWorkflow", workflow_class) do
      initial_state :asked
      transition :hear, from: :asked, to: :heard do
        await :answer, into: :answer, timeout: 3_600
        on_timeout :lapse
      end
      transition :lapse, from: :asked, to: :lapsed
    end
    first.new.run_persisted!("wait-1", adapter:)
    token = first.restore("wait-1", adapter:).awaiting.token

    second = with_stubbed_class("SpecRenameWaitSecondWorkflow", workflow_class) do
      initial_state :asked
      renamed_transition :hear, to: :listen
      transition :listen, from: :asked, to: :heard do
        await :answer, into: :answer, timeout: 3_600
        on_timeout :lapse
      end
      transition :lapse, from: :asked, to: :lapsed
    end

    expect(second.resume!("wait-1", event: :answer, token:, payload: { "said" => "yes" }, adapter:)).to eq(:resumed)
    expect(second.restore("wait-1", adapter:).state).to eq(:heard)
  end

  it "follows renames in a chain, and never takes a name the class still declares for an old one" do
    chained = with_stubbed_class("SpecRenameChainWorkflow", workflow_class) do
      initial_state :idle
      renamed_state :prepared, to: :primed
      renamed_state :primed, to: :ready
      transition :prepare, from: :idle, to: :ready do
        compute { |_step| nil }
      end
    end
    expect(chained.from_state(persisted_after_prepare).state).to eq(:ready)

    declared = with_stubbed_class("SpecRenameDeclaredWorkflow", workflow_class) do
      initial_state :idle
      renamed_state :prepared, to: :ready
      transition :prepare, from: :idle, to: :prepared do
        compute { |_step| nil }
      end
      transition :finish, from: :prepared, to: :ready do
        compute { |_step| nil }
      end
    end
    expect(declared.from_state(persisted_after_prepare).state).to eq(:prepared)
  end

  it "still refuses a name renamed to one the class does not know" do
    broken = with_stubbed_class("SpecRenameBrokenWorkflow", workflow_class) do
      initial_state :idle
      renamed_state :prepared, to: :nowhere
      transition :prepare, from: :idle, to: :ready do
        compute { |_step| nil }
      end
    end

    expect { broken.from_state(persisted_after_prepare) }.to raise_error(Smith::UnknownStateOnRestore) do |error|
      expect(error.state).to eq(:nowhere)
    end
  end

  it "keeps a subclass's renames its own, inheriting its parent's" do
    parent = second_version("SpecRenameParentWorkflow")
    child = Class.new(parent) { renamed_state :staged, to: :ready }

    expect(child.renamed_states).to eq("prepared" => "ready", "staged" => "ready")
    expect(parent.renamed_states).to eq("prepared" => "ready")
  end

  it "refuses a rename to itself, or one that names nothing" do
    expect { second_version("SpecRenameSelfWorkflow") { renamed_state :ready, to: "ready" } }
      .to raise_error(ArgumentError, /must differ/)
    expect { second_version("SpecRenameBlankWorkflow") { renamed_transition "", to: :complete } }
      .to raise_error(ArgumentError, /non-blank/)
    expect { second_version("SpecRenameSpacesWorkflow") { renamed_state "  ", to: :ready } }
      .to raise_error(ArgumentError, /non-blank/)
  end

  it "refuses a name renamed twice, or renamed back to a name it had" do
    expect { second_version("SpecRenameTwiceWorkflow") { renamed_state :prepared, to: :done } }
      .to raise_error(ArgumentError, /already renamed to "ready"/)
    expect { second_version("SpecRenameBackWorkflow") { renamed_transition :complete, to: :finish } }
      .to raise_error(ArgumentError, /never renamed back/)
    expect do
      second_version("SpecRenameLoopWorkflow") do
        renamed_state :ready, to: :staged
        renamed_state :staged, to: :prepared
      end
    end.to raise_error(ArgumentError, /never renamed back/)
  end

  it "takes two states renamed to one, but only one name renamed to a transition" do
    merged = second_version("SpecRenameMergedWorkflow") { renamed_state :staged, to: :ready }
    expect(merged.renamed_states).to eq("prepared" => "ready", "staged" => "ready")

    expect { second_version("SpecRenameTwoToOneWorkflow") { renamed_transition :close, to: :complete } }
      .to raise_error(ArgumentError, /already the new name of "finish"/)
  end

  it "gives the transition a persisted name stands for now, renames followed" do
    renamed = second_version("SpecRenameCurrentWorkflow") { renamed_transition :wrap_up, to: :finish_up }

    expect(renamed.current_transition_name("finish")).to eq(:complete)
    expect(renamed.current_transition_name(:prepare)).to eq(:prepare)
    expect(renamed.current_transition_name("wrap_up")).to be_nil
    expect(renamed.current_transition_name(nil)).to be_nil
  end

  describe "keys" do
    around do |example|
      previous = Smith.config.run_launcher
      example.run
    ensure
      Smith.config.run_launcher = previous
    end

    def recording(launches)
      Class.new { define_method(:launch) { |**call| launches << call and nil } }.new
    end

    def kid
      with_stubbed_class("SpecRenameKidWorkflow", workflow_class) do
        initial_state :idle
        transition(:work, from: :idle, to: :done) { compute { |_step| nil } }
      end
    end

    it "keys a renamed transition's steps under the first name in its chain" do
      renamed = with_stubbed_class("SpecRenameKeyNameWorkflow", workflow_class) do
        initial_state :idle
        renamed_transition :draft, to: :write
        renamed_transition "write", to: "compose"
        transition(:compose, from: :idle, to: :done) { compute { |_step| nil } }
        transition(:other, from: :done, to: :closed) { compute { |_step| nil } }
      end

      expect(renamed.transition_key_name(:compose)).to eq("draft")
      expect(renamed.transition_key_name(:other)).to eq("other")
    end

    it "runs a step a deploy cut short again under its keys, though its transition was renamed" do
      keys = []
      charging = lambda do |name, step_name, renames|
        with_stubbed_class(name, workflow_class) do
          initial_state :idle
          renames.each { |old, new| renamed_transition old, to: new }
          transition(step_name, from: :idle, to: :done) { compute { |step| keys << step.idempotency_key } }
        end
      end
      run = charging.call("SpecRenameCutFirstWorkflow", :notify, {}).new
      run.persist!("cut-1", adapter:)
      run.advance!

      charging.call("SpecRenameCutSecondWorkflow", :send_notice, { notify: :send_notice })
              .restore("cut-1", adapter:).advance!

      expect(keys.length).to eq(2)
      expect(keys.uniq.length).to eq(1)
    end

    it "makes a durable retry's next attempt under its first attempt's keys, though renamed while it waits" do
      stub_const("SpecRenameBusy", Class.new(StandardError))
      allow_any_instance_of(workflow_class).to receive(:sleep).and_raise("slept")
      seen = []
      retrying = lambda do |name, step_name, renames|
        with_stubbed_class(name, workflow_class) do
          initial_state :idle
          state :failed
          renames.each { |old, new| renamed_transition old, to: new }
          transition step_name, from: :idle, to: :done do
            compute do |step|
              seen << [step.attempt, step.idempotency_key]
              raise SpecRenameBusy, "busy" if step.attempt == 1
            end
            retry_on SpecRenameBusy, attempts: 3, backoff: 30, durable: true
            on_failure :fail
          end
        end
      end
      retrying.call("SpecRenameRetryFirstWorkflow", :charge, {}).new.run_persisted!("retry-1", adapter:)

      renamed = retrying.call("SpecRenameRetrySecondWorkflow", :bill, { charge: :bill })
      wait = renamed.restore("retry-1", adapter:).awaiting
      expect([wait.kind, wait.transition, wait.attempt]).to eq([:retry, :bill, 2])
      expect(renamed.expire_wait!("retry-1", token: wait.token, now: wait.deadline_at, adapter:)).to eq(:expired)

      expect(renamed.restore("retry-1", adapter:).run_persisted!("retry-1", adapter:).state).to eq(:done)
      expect(seen.map(&:first)).to eq([1, 2])
      expect(seen.map(&:last).uniq.length).to eq(1)
    end

    it "takes a delivery that came before the wait was stored under the block's token, though renamed since" do
      tokens = []
      awaiting = lambda do |name, step_name, renames|
        with_stubbed_class(name, workflow_class) do
          initial_state :asked
          renames.each { |old, new| renamed_transition old, to: new }
          transition step_name, from: :asked, to: :heard do
            await(:answer, into: :answer, timeout: 3_600) { |step| tokens << step.await_token }
            on_timeout :lapse
          end
          transition :lapse, from: :asked, to: :lapsed
        end
      end
      run = awaiting.call("SpecRenameEarlyFirstWorkflow", :hear, {}).new
      run.persist!("early-1", adapter:)
      run.advance!

      renamed = awaiting.call("SpecRenameEarlySecondWorkflow", :listen, { hear: :listen })

      expect(renamed.resume!("early-1", event: :answer, token: tokens.sole, payload: { "said" => "yes" }, adapter:))
        .to eq(:resumed)
      expect(renamed.restore("early-1", adapter:).state).to eq(:heard)
    end

    it "launches a map's children again under their keys, though its transition was renamed" do
      launches = []
      Smith.config.run_launcher = recording(launches)
      child = kid
      mapping = lambda do |name, step_name, renames|
        with_stubbed_class(name, workflow_class) do
          initial_state :idle
          state :failed
          renames.each { |old, new| renamed_transition old, to: new }
          transition step_name, from: :idle, to: :mapped do
            map :ids, workflow: child, max_items: 5, timeout: 60, input: ->(id, _ctx) { { id: } }, into: :results
            on_failure :fail
          end
        end
      end
      run = mapping.call("SpecRenameMapFirstWorkflow", :fan, {}).new(context: { ids: %w[a b] })
      run.persist!("map-1", adapter:)
      run.advance!

      mapping.call("SpecRenameMapSecondWorkflow", :spread, { fan: :spread })
             .restore("map-1", adapter:).run_persisted!("map-1", adapter:)

      expect(launches.length).to eq(2)
      expect(launches.map { |launch| [launch[:await_token], launch[:children].map(&:key)] }.uniq.length).to eq(1)
    end

    it "spawns children again under their keys, though its transition was renamed" do
      launches = []
      Smith.config.run_launcher = recording(launches)
      child = kid
      spawning = lambda do |name, step_name, renames|
        with_stubbed_class(name, workflow_class) do
          initial_state :idle
          renames.each { |old, new| renamed_transition old, to: new }
          transition step_name, from: :idle, to: :spawned do
            spawn :ids, workflow: child, max_items: 3, input: ->(id, _ctx) { { id: } }
          end
        end
      end
      run = spawning.call("SpecRenameSpawnFirstWorkflow", :scatter, {}).new(context: { ids: %w[a b] })
      run.persist!("spawn-1", adapter:)
      run.advance!

      spawning.call("SpecRenameSpawnSecondWorkflow", :release, { scatter: :release })
              .restore("spawn-1", adapter:).advance!

      expect(launches.length).to eq(2)
      expect(launches.map { |launch| launch[:children].map(&:key) }.uniq.length).to eq(1)
    end
  end

  describe "graph validation" do
    def codes(workflow)
      workflow.validate_graph.diagnostics.map { |diagnostic| [diagnostic.severity, diagnostic.code] }
    end

    it "reports a rename that leads to no name the workflow declares as an error" do
      broken = second_version("SpecRenameGraphBrokenWorkflow") do
        renamed_state :staged, to: :nowhere
        renamed_transition :wrap, to: :seal
      end

      expect(codes(broken)).to include(%i[error renamed_to_unknown_state], %i[error renamed_to_unknown_transition])
      expect(broken.validate_graph.status).to eq(:invalid)
    end

    it "warns of a rename whose old name the workflow still declares" do
      shadowed = second_version("SpecRenameGraphShadowWorkflow") do
        transition(:prepared_again, from: :done, to: :prepared) { compute { |_step| nil } }
      end

      expect(codes(shadowed)).to include(%i[warning rename_shadowed])
      expect(codes(shadowed)).not_to include(%i[error renamed_to_unknown_state])
    end

    it "finds nothing wanting in renames that lead to declared names" do
      expect(codes(second_version("SpecRenameGraphCleanWorkflow")).map(&:last))
        .not_to include(:rename_shadowed, :renamed_to_unknown_state, :renamed_to_unknown_transition)
    end
  end

  it "counts a run persisted in a state renamed to a final one as finished" do
    finished = with_stubbed_class("SpecRenameFinishedWorkflow", workflow_class) do
      initial_state :idle
      renamed_state :done, to: :completed
      transition :prepare, from: :idle, to: :prepared do
        compute { |_step| nil }
      end
      transition :finish, from: :prepared, to: :completed do
        compute { |_step| nil }
      end
    end

    expect(finished.current_state_name("done")).to eq(:completed)
    expect(finished.send(:terminal_payload_state?, finished, "done", nil)).to be(true)
    expect(finished.send(:terminal_payload_state?, finished, "prepared", nil)).to be(false)
  end
end
