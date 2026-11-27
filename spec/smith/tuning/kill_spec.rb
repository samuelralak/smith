# frozen_string_literal: true

require "json"
require "smith/tuning"
require "smith/testing"

# A tuning run killed with SIGKILL at every stage, then resumed by the same
# call (slice 5a design, section 2, "why a restart proposes the same
# candidates"; section 5, line 4): in a forked child, on the file store, it
# is killed after its header; mid-way through the seed's validation pass;
# after the seed's line; after iteration 1's parent minibatch; after a
# reflection line; with a reflection call in flight; mid-way through a
# child's minibatch; mid-way through a validation pass, and with a trial's
# call in flight there; after an iteration line; and before and after its
# summary. Each resume ends with the uninterrupted run's lines and summary,
# the same candidates, no recorded trial run again and no stored reflection
# asked again.
RSpec.describe "A tuning run killed at every stage, and resumed" do
  include_context "with a tuning run suite"

  let(:root) { File.join(tuning_dir, "store") }
  let(:calls) { File.join(tuning_dir, "calls.log") }
  let(:doomed) { [] }

  # A file store that kills its process at a stage: the stage's call
  # numbered as given, after the call (`:before_summary` before it).
  killing = Module.new do
    attr_accessor :kill_at

    def create_tuning(**) = super.tap { die if at?(:after_header) }
    def append_trial(**) = super.tap { die if at?(:after_trial_line) }
    def write_summary(**) = super.tap { die if at?(:after_eval_run) }

    def append_tuning_line(line:, **)
      super.tap { die if at?(:"after_#{line["type"]}_line") }
    end

    def write_tuning_summary(**)
      die if at?(:before_summary)
      super.tap { die if at?(:after_summary) }
    end

    private

    def die = Process.kill(:KILL, Process.pid).then { sleep }

    def at?(stage)
      return false unless kill_at&.first == stage

      (@counts ||= Hash.new(0))[stage] += 1
      @counts[stage] == kill_at.last
    end
  end

  before do
    stub_const("SpecKillingTuningStore", killing)
    log = calls
    kill = doomed
    usage = { input_tokens: 100, output_tokens: 20 }
    TuningRunSuite::AGENTS.each_value do |name|
      Smith::Testing.stub_agent(name, usage:, outputs: logged(log, kill, TuningRunSuite.method(:answer).curry[name]))
    end
    Smith::Testing.stub_agent(Smith::Tuning::Reflection::Runner.agent(reflection_setting),
                              usage: { input_tokens: 400, output_tokens: 60 }, outputs: logged(log, kill, reply))
  end

  # Logs the asking trial; kills the process when asked for the doomed
  # trial's numbered call.
  def logged(log, kill, answer)
    lambda do |request|
      trial = Smith::Attribution.current.trial
      Process.kill(:KILL, Process.pid).then { sleep } if kill.first == [trial, logged!(log, trial)]
      answer.call(request)
    end
  end

  # How many calls the trial has asked, this one included.
  def logged!(log, trial)
    File.open(log, "a") do |file|
      file.flock(File::LOCK_EX)
      file.puts("#{Process.pid} #{trial}")
      file.flush
      File.readlines(log).count { _1.end_with?(" #{trial}\n") }
    end
  end

  def store_for(kill_at = nil)
    Smith::Evals::Stores::File.new(root:).tap do |store|
      store.singleton_class.prepend(SpecKillingTuningStore)
      store.kill_at = kill_at
    end
  end

  def settings = tuning_settings(stop: { max_metric_calls: 80, rounds_without_improvement: nil })
  def run_id = Smith::Evals::Identity.tuning_run_id(key: tuning_key, scope: tuning_scope, suite: "spec.tuned_qa")

  def killed?(kill_at, in_flight: nil)
    pid = fork do
      finished = 1
      doomed << in_flight if in_flight
      Smith::Tuning.run(tuning_suite, **settings, store: store_for(kill_at))
      finished = 0
    ensure
      exit!(finished)
    end
    _, status = Process.wait2(pid)
    status.signaled? && status.termsig == 9
  end

  # The uninterrupted run, in a root of its own.
  let(:whole) do
    record = Smith::Tuning.run(tuning_suite, **settings, store: Smith::Evals::Stores::File.new(root: "#{root}-whole"))
    [TuningRunSuite.steady(record.lines), record.summary, record.candidates.map(&:texts)]
  end

  # Every trial with a line, and every reflection with a line, now.
  def recorded
    store = store_for
    runs = store.list_records(scope: tuning_scope, limit: 100)["records"].map { _1["eval_run_id"] }
    trials = runs.flat_map { |id| store.each_trial(scope: tuning_scope, eval_run_id: id).map { _1["trial_id"] } }
    trials + reflected(store)
  end

  def reflected(store)
    return [] unless store.read_tuning_header(scope: tuning_scope, tuning_run_id: run_id)

    lines = store.each_tuning_line(scope: tuning_scope, tuning_run_id: run_id)
    lines.select { _1["type"] == "reflection" }.map { _1["trial_id"] }
  end

  def asked_here
    File.readlines(calls).filter_map { |line| line.split.last if line.start_with?("#{Process.pid} ") }.uniq
  rescue Errno::ENOENT
    []
  end

  def resumed
    before = recorded
    record = Smith::Tuning.run(tuning_suite, **settings, store: store_for)
    { lines: TuningRunSuite.steady(record.lines), summary: record.summary, texts: record.candidates.map(&:texts),
      asked_again: asked_here & before }
  end

  def expect_whole(after)
    lines, summary, texts = whole
    expect(after).to eq(lines:, summary:, texts:, asked_again: [])
  end

  def seed_trial(sample_id)
    seed = Smith::Tuning::Candidate.seed(Smith::Prompts.components(SpecTunedQA), components: texts.keys,
                                                                                 tuning_run_id: run_id)
    eval_run = Smith::Evals::Identity.eval_run_id(key: "#{run_id}/0/seed", scope: tuning_scope,
                                                  suite: "spec.tuned_qa")
    Smith::Evals::Identity.trial_id(eval_run_id: eval_run, sample_id:, index: 0, candidate: seed.candidate_id)
  end

  {
    after_header: [:after_header, 1], mid_seed_validation: [:after_trial_line, 10],
    after_seed_line: [:after_iteration_line, 1], after_parent_minibatch: [:after_eval_run, 2],
    after_reflection_line: [:after_reflection_line, 1], mid_child_minibatch: [:after_trial_line, 35],
    mid_validation: [:after_trial_line, 53], after_iteration_line: [:after_iteration_line, 3],
    before_summary: [:before_summary, 1], after_summary: [:after_summary, 1]
  }.each do |stage, kill_at|
    it "resumes a run killed #{stage.to_s.tr("_", " ")} with the same lines and candidates, paying for nothing twice" do
      expect(killed?(kill_at)).to be(true)

      expect_whole(resumed)
    end
  end

  it "resumes a run killed with a reflection call in flight, asking that one call again" do
    reflection = Smith::Evals::Identity.reflection_trial_id(tuning_run_id: run_id, iteration: 1)
    expect(killed?(nil, in_flight: [reflection, 1])).to be(true)

    expect_whole(resumed)
    expect(asked_here).to include(reflection)
  end

  it "resumes a run killed with a trial's call in flight, and killed again while resuming" do
    expect(killed?(nil, in_flight: [seed_trial("v-007"), 2])).to be(true)
    expect(killed?([:after_reflection_line, 1])).to be(true)

    expect_whole(resumed)
  end
end
