# frozen_string_literal: true

require "fileutils"
require "json"

# What the tuning specs share: a suite of 12 training and 31 validation
# samples (tagged train and val, each its own cluster) on a named
# workflow, its named prompts, a step record as the trial schema has it,
# and records for the stores' specs (spec/fixtures/tuning/records, written
# by the record builders and checked against the schemas there).
module TuningRecords
  RECORDS = File.expand_path("../fixtures/tuning/records", __dir__)
  COMPONENTS = { "summarize.predict" => "Summarize the passages for the question.",
                 "answer.predict" => "Answer the question from the summary." }.freeze

  module_function

  def ids(prefix, count) = Array.new(count) { format("#{prefix}-%03d", _1) }
  def train_ids = ids("t", 12)
  def validation_ids = ids("v", 31)

  # Writes the dataset and returns a suite class on it; `workflow` is a
  # named Smith::Workflow subclass (a stub_const).
  def suite(dir, workflow)
    dataset(dir)
    Class.new(Smith::Evals::Suite) do
      suite_name "tuning.demo"
      dataset dir
      subject workflow:, input: ->(sample) { { question: sample.input } }, keep: %i[answer]
      trials 1
      scorer(:exact_match, version: 2) { |sample, trial| Smith::Evals::Score.match(trial.state[:answer], sample.expected) }
    end
  end

  def dataset(dir)
    lines = { "train" => train_ids, "val" => validation_ids }.flat_map do |tag, ids|
      ids.map { { "id" => _1, "input" => "q #{_1}", "expected" => "a #{_1}", "tags" => [tag] } }
    end
    FileUtils.mkdir_p(dir)
    File.binwrite(File.join(dir, "samples.jsonl"), lines.map { "#{JSON.generate(_1)}\n" }.join)
    Smith::Evals::Dataset.build_manifest(dir, name: "tuning-demo", holdout: 0.0, calibration: 0.0, seed: "demo")
  end

  def prompts = COMPONENTS.to_h { |id, text| [id, Smith::Prompt.new(id, text)] }

  # A step record as the trial schema's $defs/step has it.
  def step(components: nil, messages: nil, cost_nanos: 1_200, seq: 1)
    { "seq" => seq,
      "position" => { "workflow" => "Spec", "transition" => "run", "branch_key" => nil, "round" => nil,
                      "execution_key" => nil },
      "agent" => "spec_agent", "components" => components, "attempt_id" => "att_#{seq}", "attempt_index" => 0,
      "outcome" => "completed", "failure" => nil, "model" => "gpt-4.1-mini", "provider" => "openai",
      "settings" => { "temperature" => 1.0, "max_output_tokens" => 16_384, "thinking" => nil }, "mode" => "sync",
      "memo" => false, "offset_ms" => 0, "duration_ms" => 812,
      "tokens" => { "input" => 1_200, "output" => 300, "cache_read" => 0, "cache_write" => 0, "thinking" => 0 },
      "cost_nanos" => cost_nanos, "cost_known" => true, "stop_reason" => "stop", "sent_count" => 2,
      "messages" => messages || [{ "role" => "user", "text" => "the input" },
                                 { "role" => "assistant", "json" => { "answer" => "x" } }],
      "tool_calls" => 0, "tool_call_names" => [],
      "cut" => { "fields" => 0, "elided_messages" => 0, "content_dropped" => false } }
  end

  # The stores' records: a header, a run's lines and a summary.
  def text(name) = File.binread(File.join(RECORDS, name)).force_encoding(Encoding::UTF_8)
  def header = JSON.parse(text("header.json"))
  def lines = text("lines.jsonl").lines.map { JSON.parse(_1) }
  def summary = JSON.parse(text("summary.json"))
  def scope = header.fetch("scope")
  def tuning_run_id = header.fetch("tuning_run_id")
  def run_id(number) = format("tu_%032x", number)

  def header_for(tuning_run_id, scope: self.scope) = header.merge("tuning_run_id" => tuning_run_id, "scope" => scope)
  def line_for(tuning_run_id, index = 0) = lines.fetch(index).merge("tuning_run_id" => tuning_run_id)

  def summary_for(tuning_run_id, scope: self.scope, revision: 1, status: "running")
    summary.merge("tuning_run_id" => tuning_run_id, "scope" => scope, "summary_revision" => revision,
                  "status" => status)
  end
end
