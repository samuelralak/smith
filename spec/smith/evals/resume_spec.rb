# frozen_string_literal: true

require "smith/evals"
require "smith/testing"

# Resuming a run without paying again (slice-1a design, 5.6; 12.1, line 4):
# the store is the ledger, a trial with a line never runs again, and a start
# with a known id or key resumes, or returns the finished run, only when its
# plan digest matches.
RSpec.describe "Resuming an eval run" do
  include_context "with an eval run suite"

  let(:stop_at) { nil }
  let(:asked) { [] }
  # The trial numbered `stop_at` in this process stops it, as a kill would:
  # with an error no runner rescues (no StandardError).
  let(:hook) { ->(_trial) { raise SpecEvalKilled, "killed" if started.size == stop_at } }

  before do
    stub_const("SpecEvalKilled", Class.new(ScriptError))
    answering = method(:answer)
    Smith::Testing.stub_agent(:spec_eval_classifier, usage: { input_tokens: 100, output_tokens: 20 },
                                                     outputs: lambda { |request|
                                                       asked << Smith::Attribution.current.trial
                                                       answering.call(request)
                                                     })
  end

  def one_trial_suite(name = "SpecEvalSuite", **) = suite(name, trials: 1, **)
  def run_id = Smith::Evals::Identity.eval_run_id(key: eval_key, scope: eval_scope, suite: "spec.e2e_triage")
  def stored(kind) = eval_store.public_send(kind, scope: eval_scope, eval_run_id: run_id)
  def ids(lines) = lines.map { _1["trial_id"] }

  context "when the first launch stops after 7 trials" do
    let(:stop_at) { 8 }

    it "resumes from the store: the stub is called only for the 5 unrecorded trials, the record has one " \
       "effective line per trial, two segments, and a succeeded summary" do
      expect { run_suite(one_trial_suite) }.to raise_error(SpecEvalKilled)
      recorded = ids(stored(:each_trial).to_a)
      expect([stored(:each_segment).count, recorded.size, stored(:read_summary)]).to eq([1, 7, nil])
      eval_store.acquire_lease(scope: eval_scope, eval_run_id: run_id).release

      asked.clear
      run = run_suite(one_trial_suite)
      _, segments, lines, summary = record_of(run)

      expect(run.status).to eq(:succeeded)
      expect(asked.size).to eq(5)
      expect(asked.uniq.size).to eq(5)
      expect(asked & recorded).to eq([])
      expect(ids(lines)).to eq(ids(lines).uniq)
      expect(lines.size).to eq(12)
      expect(segments.map { _1.values_at("segment", "purpose", "resumed", "trials_already_recorded") })
        .to eq([[1, "start", false, 0], [2, "resume", true, 7]])
      expect(lines.map { _1["segment"] }).to eq(([1] * 7) + ([2] * 5))
      expect(summary["warnings"]).to include({ "code" => "resumed", "count" => 1 })
      expect(summary["usage"]["cost_nanos"]).to eq(lines.sum { _1["usage"]["cost_nanos"] })
    end

    # Design 5.4: the header records the bounds in force, so a resume keeps
    # them, whatever the configuration says now.
    it "resumes with the recording bounds its header names, not the configuration's" do
      config = Smith::Evals.config
      saved = config.recording
      long = ->(sample) { { ticket: "#{sample.input[:text]} #{"x" * 600}" } }
      expect { run_suite(one_trial_suite(input: long)) }.to raise_error(SpecEvalKilled)
      config.recording = { max_message_bytes: 256 }
      run = run_suite(one_trial_suite(input: long))
      cut = stored(:each_trial).map { |line| line["steps"].first["messages"].any? { _1["cut"] } }

      expect(run.status).to eq(:succeeded)
      expect(run.record.header.dig("recording", "max_message_bytes")).to eq(32_768)
      expect(cut).to eq([false] * 12)
    ensure
      config.recording = saved
    end
  end

  context "when the first launch stops after 2 trials" do
    let(:stop_at) { 3 }

    it "refuses a relaunch with a changed scorer version, naming the suite version, and writes nothing" do
      expect { run_suite(one_trial_suite) }.to raise_error(SpecEvalKilled)

      expect { run_suite(one_trial_suite("SpecEvalSuiteTwo", priority_version: 2)) }
        .to raise_error(Smith::Evals::ResumeMismatch) { |error| expect(error.fields).to eq(["suite.version"]) }
      expect([stored(:each_segment).count, stored(:each_trial).count]).to eq([1, 2])
    end

    it "resumes by the run's id as by its key, and refuses an id the key does not name" do
      expect { run_suite(one_trial_suite) }.to raise_error(SpecEvalKilled)

      run = Smith::Evals.run(one_trial_suite, scope: eval_scope, eval_run_id: run_id, store: eval_store)
      expect([run.eval_run_id, run.status]).to eq([run_id, :succeeded])
      expect { run_suite(one_trial_suite, eval_run_id: "er_#{"0" * 32}") }
        .to raise_error(ArgumentError, /is not the run idempotency key/)
    end
  end

  it "returns a finished run for its idempotency key without running anything when the plan digest matches, " \
     "and raises ResumeMismatch when the suite changed" do
    first = run_suite(one_trial_suite)
    asked.clear
    again = run_suite(one_trial_suite)

    expect(asked).to eq([])
    expect(again.eval_run_id).to eq(first.eval_run_id)
    expect(again.summary).to eq(first.summary)
    expect(stored(:each_segment).count).to eq(1)
    expect { run_suite(one_trial_suite("SpecEvalSuiteTwo", priority_version: 2)) }
      .to raise_error(Smith::Evals::ResumeMismatch) { |error| expect(error.fields).to eq(["suite.version"]) }
    expect { run_suite(one_trial_suite("SpecEvalSuiteThree", trials: 2)) }
      .to raise_error(Smith::Evals::ResumeMismatch) do |error|
        expect(error.fields).to eq(%w[suite.version plan.trials_per_sample])
      end
    expect(asked).to eq([])
  end

  # Two starts of one key: the second reads no summary, then the first
  # finishes and lets go of its lease, and the second takes it. The store
  # here hides the summary from the second start's first read.
  it "returns a run that finished while its start waited for the lease, launching nothing" do
    first = run_suite(one_trial_suite)
    racing = Class.new(SimpleDelegator) do
      def read_summary(**)
        return __getobj__.read_summary(**) if @read

        @read = true
        nil
      end
    end
    asked.clear
    again = run_suite(one_trial_suite, store: racing.new(eval_store))

    expect(again.summary).to eq(first.summary)
    expect(asked).to eq([])
    expect(stored(:each_segment).count).to eq(1)
  end
end
