# frozen_string_literal: true

require "json"
require "smith/evals"
require "smith/testing"

# A run killed with SIGKILL at every stage of its life, then resumed
# (slice-1a design, 5.6 and 12.1, line 4): in a forked child, on the file
# store, at concurrency 2, the run is killed just after its header, its
# lease or its launch line, mid-trial (a provider call in flight), after a
# trial line, mid-write of a trial line (a torn tail), before and after its
# summary, and once more while resuming. Each resume ends with every
# planned trial on exactly one line, no recorded trial asked again, the
# torn tail cut, and the summary's spend the lines' own.
RSpec.describe "An eval run killed at every stage, and resumed" do
  include_context "with an eval run suite"

  let(:root) { File.join(dataset_dir, "store") }
  let(:calls) { File.join(dataset_dir, "calls.log") }
  let(:kill_trial) { [] }
  let(:run_id) { Smith::Evals::Identity.eval_run_id(key: eval_key, scope: eval_scope, suite: "spec.e2e_triage") }
  let(:run_dir) { File.join(root, "v1/scopes", Smith::Evals::Identity.scope_digest(eval_scope), "runs", run_id) }

  # A file store that kills its process at a stage: the stage's call
  # numbered as given. Mid-line it first writes part of the line, as a
  # kill inside the write leaves it.
  killing = Module.new do
    attr_accessor :kill_at, :run_dir

    def create_record(**) = super.tap { die if at?(:after_header) }
    def acquire_lease(**) = super.tap { die if at?(:after_lease) }
    def append_segment(**) = super.tap { die if at?(:after_segment) }

    def append_trial(line:, **)
      if at?(:mid_line)
        File.open(File.join(run_dir, "trials.jsonl"), "ab") { _1.write(JSON.generate(line)[0, 300]) }
        die
      end
      super.tap { die if at?(:after_line) }
    end

    def write_summary(**)
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
    stub_const("SpecKillingStore", killing)
    log = calls
    doomed = kill_trial
    answering = method(:answer)
    Smith::Testing.stub_agent(:spec_eval_classifier, usage: { input_tokens: 100, output_tokens: 20 },
                                                     outputs: lambda { |request|
                                                       trial = Smith::Attribution.current.trial
                                                       File.open(log, "a") { _1.puts("#{Process.pid} #{trial}") }
                                                       Process.kill(:KILL, Process.pid).then { sleep } if
                                                         doomed.first == trial
                                                       answering.call(request)
                                                     })
  end

  def store_for(kill_at = nil)
    Smith::Evals::Stores::File.new(root:).tap do |store|
      store.singleton_class.prepend(SpecKillingStore)
      store.kill_at = kill_at
      store.run_dir = run_dir
    end
  end

  # Whether a child that runs the suite until it is killed was ended by
  # SIGKILL.
  def killed?(kill_at, mid_trial: nil, concurrency: 2)
    pid = fork do
      finished = 1
      kill_trial << mid_trial if mid_trial
      run_suite(suite(concurrency:), store: store_for(kill_at))
      finished = 0
    ensure
      exit!(finished)
    end
    _, status = Process.wait2(pid)
    status.signaled? && status.termsig == 9
  end

  def lines
    return [] unless File.exist?(File.join(run_dir, "trials.jsonl"))

    store_for.each_trial(scope: eval_scope, eval_run_id: run_id).to_a
  end

  def asked_here
    File.readlines(calls).filter_map { |line| line.split.last if line.start_with?("#{Process.pid} ") }
  rescue Errno::ENOENT
    []
  end

  def resumed
    before = lines.map { _1["trial_id"] }
    run = run_suite(suite(concurrency: 2), store: store_for)
    [run, before, lines]
  end

  # What a resumed run must be: whole, no recorded trial asked again, its
  # spend its lines' own, no torn tail left.
  def whole(run, before, after)
    summary = run.summary
    { status: run.status, lines: after.size, trials: after.map { _1["trial_id"] }.uniq.size,
      asked_again: asked_here & before, not_run: summary.dig("outcomes", "not_run"),
      unspent: summary.dig("usage", "cost_nanos") - after.sum { _1.dig("usage", "cost_nanos") }, torn: torn? }
  end

  def torn? = !File.binread(File.join(run_dir, "trials.jsonl")).end_with?("\n")

  def expect_whole(run, before, after)
    expect(whole(run, before, after)).to eq(status: :succeeded, lines: 36, trials: 36, asked_again: [], not_run: 0,
                                            unspent: 0, torn: false)
  end

  # Stage => [where it is killed, lines recorded before the resume, launches].
  {
    after_header: [[:after_header, 1], 0, %w[start]],
    after_lease: [[:after_lease, 1], 0, %w[start]],
    after_segment: [[:after_segment, 1], 0, %w[start resume]],
    after_line: [[:after_line, 9], 9, %w[start resume]],
    mid_line: [[:mid_line, 9], 8, %w[start resume]],
    before_summary: [[:before_summary, 1], 36, %w[start resume]],
    after_summary: [[:after_summary, 1], 36, %w[start]]
  }.each do |stage, (kill_at, recorded, purposes)|
    it "resumes a run killed #{stage.to_s.tr("_", " ")}, paying for no recorded trial again" do
      # Mid-line, one worker: the store appends under its own lock, so a
      # torn tail is one writer's, killed inside its write.
      expect(killed?(kill_at, concurrency: stage == :mid_line ? 1 : 2)).to be(true)
      run, before, after = resumed

      expect(before.size).to eq(recorded)
      expect_whole(run, before, after)
      expect(run.record.segments.map { _1["purpose"] }).to eq(purposes)
    end
  end

  it "resumes a run killed mid-trial, a provider call in flight, and killed again while resuming" do
    expect(killed?(nil, mid_trial: trial_id("s-05", 0))).to be(true)
    first = lines.map { _1["trial_id"] }
    expect(killed?(nil, mid_trial: trial_id("s-09", 1))).to be(true)
    run, before, after = resumed

    expect(first).not_to include(trial_id("s-05", 0))
    expect(before).to include(*first)
    expect_whole(run, before, after)
    expect(run.record.segments.map { _1["purpose"] }).to eq(%w[start resume resume])
  end
end
