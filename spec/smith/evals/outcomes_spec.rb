# frozen_string_literal: true

require "smith/evals"
require "smith/testing"

# Outcome classification (slice-1a design, 6.2 and 6.3): every way a subject
# ends, run for real through the in-process driver (a stubbed agent, the
# local server or a compute step raising Smith's own error), classified
# into an outcome and a reason with who caused it, whether it is retried and
# whether it stops the run.
RSpec.describe Smith::Evals::Outcomes do
  include_context "with an eval trial"

  let(:testing) { Smith::Testing }
  let(:driver) { Smith::Evals::Drivers::InProcess.new }

  around do |example|
    saved = Smith.config.interrupting_errors
    example.run
  ensure
    Smith.config.interrupting_errors = saved
    testing.reset!
  end

  # A host error some suites name as their own infrastructure.
  host_down = Class.new(StandardError)

  before { stub_const("SpecHostDown", host_down) }

  def driven(workflow, infrastructure_errors: [])
    trial = Smith::Evals::TrialSpec.for(eval_run_id:, scope: eval_scope, sample:, trial_index: 0,
                                        subject: Smith::Evals::Subject.new(workflow:, input: ->(_s) { {} }))
    recorder = Smith::Evals::Recorder.new(trial.trial_id)
    result = Smith::Evals::Recording.attach(recorder) { driver.run(trial, trial.context) }
    described_class.classify(result, steps: recorder.steps, infrastructure_errors:)
  end

  # A one-step run whose compute step raises `error`, routed to its failed
  # state; `routed: false` lets the error out of run!.
  def raising(error, routed: true, **)
    klass = with_stubbed_class("SpecOutcomeRaising", workflow_class) do
      initial_state :idle
      state :failed
      transition :work, from: :idle, to: :done do
        compute { |_step| raise error.respond_to?(:call) ? error.call : error }
        on_failure :fail if routed
      end
    end
    driven(klass, **)
  end

  def asked(status = nil, body = nil, **)
    server.reply(json: body, status:) if status
    driven(asking("SpecOutcomeAsking"), **)
  end

  def reading(outcome)
    [outcome.outcome, outcome.reason&.fetch("code"), outcome.reason&.fetch("by"),
     outcome.retryable, outcome.stops_run]
  end

  def expect_reason_valid(outcome)
    return if outcome.reason.nil?

    errors = EvalsSchema.errors(outcome.reason, schema: "common", strict: true, pointer: "#/$defs/reason")
    expect(errors).to eq([]), outcome.reason.inspect
  end

  def wrapped(outer, inner)
    raise inner
  rescue StandardError
    raise outer
  end

  def chained(outer, inner)
    wrapped(outer, inner)
  rescue StandardError => e
    e
  end

  describe "from how the subject ended (6.2)" do
    before do
      agent("SpecOutcomeAgent")
      testing.stub_agent(:spec_ledger_agent, outputs: "Fine.")
    end

    it "takes a run that ended, not in its failed state, as answered, to be scored" do
      outcome = asked
      expect([outcome.outcome, outcome.reason, outcome.retryable,
              outcome.stops_run]).to eq([:answered, nil, false, false])
    end

    it "fails a run that ended in its failed state with no error: failed_state" do
      klass = with_stubbed_class("SpecOutcomeGaveUp", workflow_class) do
        initial_state :idle
        state :failed
        transition(:give_up, from: :idle, to: :failed) { compute { |_step| nil } }
      end
      expect(reading(driven(klass))).to eq([:subject_failed, "failed_state", "subject", false, false])
    end

    it "takes a run left waiting on anything but a retry as an error, not retried: subject_waited" do
      klass = with_stubbed_class("SpecOutcomeWaits", workflow_class) do
        initial_state :idle
        state :failed
        transition :approve, from: :idle, to: :done do
          await :approval, into: :approval, timeout: 3_600
          on_failure :fail
        end
      end
      outcome = driven(klass)
      expect(reading(outcome)).to eq([:error, "subject_waited", "infrastructure", false, false])
      expect(outcome.reason["detail"]).to eq("the run waits (await), which the driver cannot deliver")
    end

    it "retries the driver's own failure, and stops the run on a scope conflict" do
      expect(reading(described_class.driver_failed(IOError.new("the mapping's host broke"))))
        .to eq([:error, "driver_error", "infrastructure", true, false])
      conflict = described_class.driver_failed(Smith::Evals::ScopeConflict.new("sets tenant"))
      expect(reading(conflict)).to eq([:error, "scope_conflict", "eval_run", false, true])
      expect(conflict.reason["detail"]).to eq("sets tenant")
    end

    it "takes a trial a scorer could not decide, or that raised, as unscored by the grader" do
      trial = Smith::Evals::Trial.new(id: trial_spec.trial_id, index: 0, sample_id: "t-1", outcome: :answered,
                                      state: {}, output: nil, final_state: :done, failure: nil, steps: [],
                                      tool_calls: [], usage: nil, duration_ms: 1)
      raising_scorer = Smith::Evals::Scorer::Block.new(name: :category, version: 1) { |_s, _t| raise "a bug" }
      undecided = Smith::Evals::Scorer::Block.new(name: :priority, version: 1) { |_s, _t| Smith::Evals::Score.unscored("no priority") }
      passing = Smith::Evals::Scorer::Block.new(name: :tone, version: 1) { |_s, _t| Smith::Evals::Score.pass }
      scores = [raising_scorer, undecided, passing].to_h { [_1.name, _1.evaluate(sample, trial)] }

      expect(reading(described_class.scored(scores.slice("tone")))).to eq([:scored, nil, nil, false, false])
      expect(reading(described_class.scored(scores))).to eq([:unscored, "scorer_raised", "grader", false, false])
      expect(reading(described_class.scored(scores.slice("priority", "tone"))))
        .to eq([:unscored, "grader_undecided", "grader", false, false])
    end
  end

  describe "from Smith's errors, before their families (6.3)" do
    it "takes an interrupting error first: a 402 the host lists is interrupted, retried" do
      agent("SpecOutcomeCredit")
      Smith.config.interrupting_errors = [RubyLLM::PaymentRequiredError]
      body = { type: "error", error: { type: "billing_error", message: "card declined" } }
      expect(reading(asked("402 Payment Required", body))).to eq([:error, "interrupted", "infrastructure", true, false])
      expect(reading(asked("402 Payment Required", body, infrastructure_errors: [RubyLLM::PaymentRequiredError])))
        .to eq([:error, "interrupted", "infrastructure", true, false])
    end

    it "takes a host's own infrastructure error, found among the causes, as host_infrastructure, retried" do
      error = chained(Smith::WorkflowError.new("the step failed"), SpecHostDown.new("pg down"))
      expect(reading(raising(error, infrastructure_errors: [SpecHostDown])))
        .to eq([:error, "host_infrastructure", "infrastructure", true, false])
      expect(reading(raising(error))).to eq([:subject_failed, "unhandled_error", "subject", false, false])
    end

    it "classifies the run credential errors and a scrubbed error by class, never retried" do
      refused = lambda { |kind|
        Smith::ProviderCredentialsRefused.new(kind:, provider: :anthropic, model_id: "m",
                                              source_error_class: "RubyLLM::Error")
      }
      expected = {
        Smith::ProviderCredentialsMissing.new => [:error, "credentials_missing", "infrastructure", false, true],
        Smith::ProviderCredentialsError.new => [:error, "credentials_lookup_failed", "infrastructure", false, true],
        refused.call(:key_refused) => [:error, "key_refused", "infrastructure", false, true],
        refused.call(:permission) => [:error, "provider_permission", "infrastructure", false, true],
        Smith::ScrubbedError.new(original_class: "IOError") => [:error, "scrubbed_error", "infrastructure", false,
                                                                false]
      }
      expected.each { |error, reading| expect(reading(raising(error))).to eq(reading), error.class.name }
    end

    it "classifies an uncertain tool outcome, or a nested run's failure, by its cause" do
      deadline = chained(Smith::ToolOutcomeUncertain.new("unsure"), Smith::DeadlineExceeded.new("out of time"))
      nested = chained(Smith::WorkflowError.new("the child failed"), Smith::GuardrailFailed.new("blocked"))

      expect(reading(raising(deadline))).to eq([:limit_hit, "deadline", "subject", false, false])
      expect(reading(raising(nested))).to eq([:subject_failed, "guardrail_failed", "subject", false, false])
      expect(reading(raising(Smith::ToolOutcomeUncertain.new("unsure"))))
        .to eq([:subject_failed, "tool_outcome_uncertain", "subject", false, false])
      expect(reading(raising(Smith::WorkflowError.new("a router's bad output"))))
        .to eq([:subject_failed, "workflow_error", "subject", false, false])
    end

    # Ruby gives an error raised inside a rescue that error as its cause:
    # only a plain WorkflowError is a wrapper; a subclass reads as itself.
    it "reads a WorkflowError subclass raised while rescuing another as itself, not by its cause" do
      ledger = chained(Smith::BudgetLedgerError.new("the host's ledger broke"), IOError.new("disk full"))

      expect(ledger.cause).to be_a(IOError)
      expect(reading(raising(ledger))).to eq([:error, "ledger_error", "infrastructure", true, false])
    end
  end

  describe "from Smith's failure families (6.3)" do
    let(:transition) { :work }

    # Each row: the error raised in a compute step, and how it reads.
    def rows # rubocop:disable Metrics/AbcSize, Metrics/MethodLength -- the table is one list
      boom = IOError.new("boom")
      {
        Smith::DeterministicStepFailure.new("x") => [:subject_failed, "step_failed", "subject", false, false],
        Smith::ToolFailureNotificationFailed.new(dispatch_error: boom, notification_error: boom) =>
          [:subject_failed, "tool_failed", "subject", false, false],
        Smith::ToolCaptureFailed.new(tool_name: "lookup", reason: :capture_empty) =>
          [:subject_failed, "tool_failed", "subject", false, false],
        Smith::ToolExecutionNotAdmitted.new("x") => [:subject_failed, "tool_not_admitted", "subject", false, false],
        Smith::BoundedCompletionError.new("x") => [:subject_failed, "tool_loop_bound", "subject", false, false],
        Smith::PersistedFailureInvalid.new("x") => [:error, "persistence", "infrastructure", true, false],
        Smith::ToolGuardrailFailed.new("x") => [:subject_failed, "tool_guardrail_failed", "subject", false, false],
        Smith::DeadlineExceeded.new("x") => [:limit_hit, "deadline", "subject", false, false],
        Smith::RequestOutcomeUncertain.new("x") =>
          [:error, "request_outcome_uncertain", "infrastructure", false, false],
        Smith::BudgetUnavailable.new => [:limit_hit, "ledger_refused", "subject", false, false],
        Smith::BudgetExceeded.new("x") => [:limit_hit, "budget", "subject", false, false],
        Smith::GuardrailFailed.new("x") => [:subject_failed, "guardrail_failed", "subject", false, false],
        Smith::OutputTruncated.new(agent_name: :a, model_used: "m") =>
          [:subject_failed, "output_truncated", "subject", false, false],
        Smith::OutputRefused.new(agent_name: :a, model_used: "m") =>
          [:subject_failed, "output_refused", "subject", false, false],
        Smith::OutputInvalid.new(agent_name: :a, model_used: "m") =>
          [:subject_failed, "output_invalid", "subject", false, false],
        Smith::OutputFailure.new(agent_name: :a, model_used: "m") =>
          [:subject_failed, "output_unusable", "subject", false, false],
        Smith::BlankAgentOutputError.new(agent_name: :a, model_used: "m") =>
          [:subject_failed, "blank_output", "subject", false, false],
        Smith::BatchResultFailed.new(kind: :errored) => [:error, "batch_result_failed", "infrastructure", true, false],
        Smith::BatchRequestChanged.new("x") => [:error, "batch_request_changed", "infrastructure", true, false],
        Smith::AgentError.new("x") => [:error, "agent_error", "infrastructure", true, false],
        Smith::WaitTimedOut.new(transition:, event: :approval, deadline_at: Time.now.utc) =>
          [:subject_failed, "wait_timed_out", "subject", false, false],
        Smith::ChildRunsFailed.new(transition:, failed_refs: [0], total: 1) =>
          [:subject_failed, "child_runs_failed", "subject", false, false],
        Smith::ContentUnavailable.new("x") => [:subject_failed, "content_unavailable", "subject", false, false],
        Smith::PersistedStateTooLarge.new(key: "k", bytes: 2, limit: 1) =>
          [:subject_failed, "state_too_large", "subject", false, false],
        Smith::BatchRequestInvalid.new("x") => [:subject_failed, "provider_rejected_request", "subject", false, false],
        Smith::BudgetLedgerError.new => [:error, "ledger_error", "infrastructure", true, false],
        Smith::UnresolvedTransitionError.new(:next, Object, :idle) =>
          [:subject_failed, "unresolved_transition", "subject", false, false],
        Smith::UnroutedDeterministicStep.new(transition:, routes: [:a]) =>
          [:error, "definition_error", "subject", false, true],
        Smith::UndeclaredContextKey.new(key: :x, persisted_keys: []) =>
          [:error, "definition_error", "subject", false, true],
        Smith::ArtifactStoreMissing.new("x") => [:error, "definition_error", "subject", false, true],
        Smith::StreamSinkMissing.new("x") => [:error, "definition_error", "subject", false, true],
        Smith::BatchQueueMissing.new("x") => [:error, "definition_error", "subject", false, true],
        Smith::BatchModeUnavailable.new("x") => [:error, "definition_error", "subject", false, true],
        Smith::MaxTransitionsExceeded.new("x") => [:limit_hit, "max_transitions", "subject", false, false],
        Smith::ToolPolicyDenied.new("x") => [:subject_failed, "tool_denied", "subject", false, false],
        Smith::ToolDispatchRejected.new("x") => [:subject_failed, "tool_denied", "subject", false, false],
        Smith::AgentRegistryError.new("x") => [:error, "definition_error", "subject", false, true],
        Smith::PricingConfigurationError.new("x") => [:error, "configuration_error", "infrastructure", false, true],
        Smith::Testing::UnstubbedCall.new("x") => [:error, "configuration_error", "infrastructure", false, true],
        Smith::SerializationError.new("x") => [:error, "persistence", "infrastructure", true, false],
        Smith::PersistenceIOError.new(operation: :store, cause: boom) =>
          [:error, "persistence", "infrastructure", true, false],
        Smith::PersistenceVersionConflict.new(key: "k", expected: 1, actual: 2) =>
          [:error, "persistence", "infrastructure", true, false],
        Smith::PersistenceSchemaMismatch.new(workflow: "W", stored: 1, current: 2) =>
          [:error, "persistence", "infrastructure", true, false],
        Smith::PersistencePayloadConflict.new(key: "k") => [:error, "persistence", "infrastructure", true, false],
        Smith::StepInProgressOnRestore.new(workflow: "W", persistence_key: "k") =>
          [:error, "persistence", "infrastructure", true, false],
        Smith::UnknownStateOnRestore.new(workflow: "W", persistence_key: "k", state: :x) =>
          [:error, "persistence", "infrastructure", true, false],
        Smith::UnknownTransitionOnRestore.new(workflow: "W", persistence_key: "k", transition: :x) =>
          [:error, "persistence", "infrastructure", true, false],
        Smith::SeedMismatch.new(workflow: "W", stored_digest: "a", current_digest: "b") =>
          [:error, "persistence", "infrastructure", true, false],
        IOError.new("a host's own bug") => [:subject_failed, "unhandled_error", "subject", false, false]
      }
    end

    it "reads every family's row from the real error a step raised, routed to failed or out of run!" do
      rows.each do |error, reading|
        outcome = raising(error)
        expect(reading(outcome)).to eq(reading), error.class.name
        expect(reading(raising(error, routed: false))).to eq(reading), "#{error.class.name} raised"
        expect(outcome.reason["detail"]).to eq(error.class.name)
        expect_reason_valid(outcome)
      end
    end

    it "names the error's family as Smith records it, other for an error with none" do
      expect(raising(Smith::OutputInvalid.new(agent_name: :a, model_used: "m")).family).to eq("output_failure")
      expect(raising(Smith::MaxTransitionsExceeded.new("x")).family).to eq("other")
      agent("SpecOutcomeFamily")
      testing.stub_agent(:spec_ledger_agent, outputs: "Fine.")
      expect(asked.family).to be_nil
    end
  end

  describe "the provider rows (6.3), from the kinds the seam recorded" do
    before { agent("SpecOutcomeProvider") }

    def error_body(type, text) = { type: "error", error: { type:, message: text } }

    it "stops the run on a refused key, account, model access or missing model; fails the sample on a bad request" do
      expected = {
        "401 Unauthorized" => [:error, "key_refused", "infrastructure", false, true],
        "402 Payment Required" => [:error, "out_of_credit", "infrastructure", false, true],
        "403 Forbidden" => [:error, "provider_permission", "infrastructure", false, true],
        "404 Not Found" => [:error, "model_unavailable", "infrastructure", false, true],
        "400 Bad Request" => [:subject_failed, "provider_rejected_request", "subject", false, false]
      }
      expected.each do |status, reading|
        outcome = asked(status, error_body("error", "the provider says no, key sk-live-1"))
        expect(reading(outcome)).to eq(reading), status
        expect(outcome.reason["detail"]).not_to include("sk-live")
        expect_reason_valid(outcome)
      end
    end

    it "reads the kind recorded on the failed attempt of the error's own model and provider" do
      error = Smith::ProviderPermanentFailure.new("refused", provider: :anthropic, model_id: "claude-a",
                                                             source_error_class: "RubyLLM::UnauthorizedError")
      result = Smith::Evals::SubjectResult.raised(nil, error, keep: [])
      step = lambda { |model, kind|
        { "outcome" => "failed", "model" => model, "provider" => "anthropic",
          "failure" => { "kind" => kind } }
      }
      steps = [step.call("claude-a", "key_refused"), step.call("claude-b", "rejected")]

      expect(reading(described_class.classify(result, steps:)))
        .to eq([:error, "key_refused", "infrastructure", false, true])
      expect(reading(described_class.classify(result, steps: steps.reverse.map { _1.merge("provider" => "openai") })))
        .to eq([:subject_failed, "provider_rejected_request", "subject", false, false])
    end

    it "retries an agent error whose last failed attempt was overloaded or lost: provider_unavailable" do
      overloaded = error_body("overloaded_error", "Overloaded")
      outcome = asked("529 Overloaded", overloaded)
      expect(reading(outcome)).to eq([:error, "provider_unavailable", "infrastructure", true, false])
    end

    it "reads provider_unavailable from the last failed attempt, not an earlier one" do
      result = Smith::Evals::SubjectResult.raised(nil, Smith::AgentError.new("no candidate answered"), keep: [])
      failed = ->(kind) { { "outcome" => "failed", "failure" => { "kind" => kind } } }

      expect(reading(described_class.classify(result, steps: [failed.call("rejected"), failed.call("transient")])))
        .to eq([:error, "provider_unavailable", "infrastructure", true, false])
      expect(reading(described_class.classify(result, steps: [failed.call("transport"), failed.call("rejected")]))[1])
        .to eq("agent_error")
    end

    it "takes a call no stub answers, under :refuse, as the suite's configuration error" do
      testing.unstubbed = :refuse
      expect(reading(asked)).to eq([:error, "configuration_error", "infrastructure", false, true])
    ensure
      testing.unstubbed = :send
    end

    it "takes a ledger's refusal and a cut-off reply from the real run as the subject's limit and failure" do
      refusing = asking("SpecOutcomeLedger") { ledger_class.new(admit: false) }
      expect(reading(driven(refusing))).to eq([:limit_hit, "ledger_refused", "subject", false, false])
      testing.stub_agent(:spec_ledger_agent, outputs: "Cut", stop_reason: "max_tokens")
      expect(reading(asked)).to eq([:subject_failed, "output_truncated", "subject", false, false])
      testing.stub_agent(:spec_ledger_agent, outputs: "")
      expect(reading(asked)).to eq([:subject_failed, "blank_output", "subject", false, false])
    end
  end
end
