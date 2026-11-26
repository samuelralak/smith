# frozen_string_literal: true

require "smith/evals"
require "smith/testing"

# A suite end to end on stubs (slice-1a design, 12.1, line 1): every kind
# of trial a run meets, written as a record whose header, launch lines,
# trial lines and summary all fit the published schemas, strict mode
# included; and the same suite at concurrency 3 writes the same trial lines
# as at concurrency 1, times aside.
RSpec.describe "An eval run, end to end" do
  include_context "with an eval run suite"

  let(:faults) { { trial_id("s-07", 1) => 1, trial_id("s-08", 2) => 99 } }

  it "runs a 12-sample suite with three trials, a failing sample, an output repair, an errored trial that " \
     "recovers on retry and one that does not, and an unscored score, to a record valid as published and strict" do
    run = run_suite(suite)
    header, segments, lines, summary = record_of(run)

    expect(run.status).to eq(:succeeded)
    expect(summary["outcomes"]).to eq("scored" => 29, "subject_failed" => 3, "limit_hit" => 0, "unscored" => 3,
                                      "error" => 1, "not_run" => 0)
    expect(summary["causes"]).to eq("subject_failed" => { "output_invalid" => 3 }, "limit_hit" => {},
                                    "unscored" => { "grader_undecided" => 3 },
                                    "error" => { "host_infrastructure" => 1 }, "not_run" => {})
    expect(summary["retries"]).to eq("trials_retried" => 2, "attempts_retried" => 3)
    expect(summary["warnings"]).to eq([{ "code" => "errors_present", "count" => 1 },
                                       { "code" => "unscored_present", "count" => 3 }])
    expect([run.result(:category).successes, run.result(:category).n]).to eq([10, 12])
    expect([run.result(:category, reducer: :mean).reducer, run.result(:category).reducer]).to eq(%w[mean majority])
    expect(run.result(:tone).method_name).to eq("t")

    by_id = lines.to_h { [[_1["sample_id"], _1["trial_index"]], _1] }
    repaired = by_id[["s-05", 0]]
    expect(repaired["steps"].map { _1["outcome"] }).to eq(%w[completed completed])
    expect(repaired["outcome"]).to eq("scored")
    recovered = by_id[["s-07", 1]]
    expect(recovered["attempts"].map { _1["outcome"] }).to eq(%w[error scored])
    expect(recovered["latency_ms"]).to eq(recovered["attempts"].last["duration_ms"])
    failed = by_id[["s-08", 2]]
    expect(failed["attempts"].map { _1.dig("reason", "code") }).to eq(%w[host_infrastructure] * 3)
    expect(failed.values_at("outcome", "scores")).to eq(["error", {}])
    expect(failed["error"]).to eq("class" => "SpecEvalHostDown", "family" => "other",
                                  "message" => "the host's database is down")
    expect(by_id[["s-04", 1]]["scores"]["category"]["source"]).to eq("outcome_rule")

    expect(header.values_at("kind", "idempotency_key", "started_by", "group", "candidate"))
      .to eq(["eval", eval_key, nil, nil, nil])
    expect(header["plan"]).to include("trials_per_sample" => 3, "planned_trials" => 36, "concurrency" => 1,
                                      "error_retries" => 2, "max_cost_nanos" => nil)
    expect(header.dig("suite", "measure_digest")).to eq(suite.measure_digest(scope: eval_scope))
    expect(header.dig("selection", "sample_count")).to eq(12)
    expect(header["subject"]).to include("workflow" => "SpecEvalTriage", "keep" => ["triage"], "version" => 1)
    expect(header["driver"]).to eq("name" => "Smith::Evals::Drivers::InProcess", "form" => "in_process",
                                   "max_concurrency" => 8, "isolation" => "none")
    expect(header["recording"]).to include("content" => true, "max_steps" => 256)
    expect(schema_errors(header, "record-header")).to eq([])
    segments.each { expect(schema_errors(_1, "segment")).to eq([]) }
    lines.each { expect(schema_errors(_1, "trial")).to eq([]), _1["trial_id"] }
    expect(schema_errors(summary, "summary")).to eq([])
    expect(lines.size).to eq(36)
  end

  it "writes the same effective trial lines (ignoring times) at concurrency 3 as at concurrency 1" do
    alone = run_suite(suite("SpecEvalSuiteOne", concurrency: 1))
    calls = fault_calls.dup
    fault_calls.clear
    shared = Smith::Evals::Stores::Memory.new
    together = run_suite(suite("SpecEvalSuiteThree", concurrency: 3), store: shared)

    timeless = lambda do |line|
      line.except("started_at", "ended_at", "duration_ms", "latency_ms")
          .merge("attempts" => line["attempts"].map { _1.except("started_at", "duration_ms") },
                 "steps" => line["steps"].map { _1.except("attempt_id", "offset_ms", "duration_ms") })
    end
    effective = ->(run) { run.record.each_trial.map(&timeless).sort_by { _1["trial_id"] } }
    expect(together.record.header.dig("plan", "concurrency")).to eq(3)
    expect(effective.call(together)).to eq(effective.call(alone))
    expect(fault_calls).to eq(calls)
    expect(together.summary.except("written_at", "started_at", "ended_at", "duration_ms", "segments", "latency_ms"))
      .to eq(alone.summary.except("written_at", "started_at", "ended_at", "duration_ms", "segments", "latency_ms"))
  end
end
