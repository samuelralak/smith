# frozen_string_literal: true

require "json"

# Eval records for the stores' specs, copied verbatim from the slice 1a
# contract examples (spec/fixtures/evals/records): the failing-rerun record's
# header, three launch lines and revision-2 summary, twelve of its trial
# lines (the first three, and every one that is not a revision-1 "scored"
# line, so both revisions of the two rerun trials), and the failing record's
# revision-1 summary of the same run. Builders give another run's records by
# replacing only fields the schemas allow to vary, so each stays valid.
module EvalRecords
  DIRECTORY = File.expand_path("../fixtures/evals/records", __dir__)
  RUN = File.join(DIRECTORY, "failing-rerun")
  FILES = %w[header.json segments.jsonl trials.jsonl summary.json].freeze
  # The time a store's clock gives in the specs, as cancel requests record it.
  CLOCK_AT = Time.utc(2026, 11, 22, 8, 1, 2.5r)

  module_function

  def text(name) = File.binread(File.join(RUN, name)).force_encoding(Encoding::UTF_8)
  def lines(name) = text(name).lines.map { JSON.parse(_1) }
  def header = JSON.parse(text("header.json"))
  def segments = lines("segments.jsonl")
  def trials = lines("trials.jsonl")
  def summary = JSON.parse(text("summary.json"))
  def first_summary = JSON.parse(File.read(File.join(DIRECTORY, "failing-summary.json"), encoding: "UTF-8"))
  def scope = header.fetch("scope")
  def eval_run_id = header.fetch("eval_run_id")

  # er_ and 32 hex digits from a number, for runs of the specs' own.
  def run_id(number) = format("er_%032x", number)
  def trial_id(number) = format("tr_%032x", number)

  def header_for(eval_run_id, scope: self.scope, created_at: header.fetch("created_at"), suite: nil)
    header.merge("eval_run_id" => eval_run_id, "scope" => scope, "created_at" => created_at).tap do |value|
      value["suite"] = value.fetch("suite").merge("name" => suite) if suite
    end
  end

  def segment_for(eval_run_id, number = 1)
    segments.first.merge("eval_run_id" => eval_run_id, "segment" => number)
  end

  def trial_for(eval_run_id, number, revision: 1, output: nil)
    line = trials.first.merge("eval_run_id" => eval_run_id, "trial_id" => trial_id(number),
                              "trial_revision" => revision)
    output.nil? ? line : line.merge("output" => output)
  end

  def summary_for(eval_run_id, scope: self.scope, revision: 1, status: "succeeded")
    summary.merge("eval_run_id" => eval_run_id, "scope" => scope, "summary_revision" => revision,
                  "status" => status)
  end

  # The JSON text a value reads back as: equal texts are byte for byte the
  # same record (key order, 1 against 1.0, -0.0 included).
  def json(value) = JSON.generate(value)
end
