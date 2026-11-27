# frozen_string_literal: true

require "smith/evals"
require "smith/testing"

# The runner's loop (slice-1a design, 5.7, 6.2 and 6.4): trial-index-major
# order, retries put back with their backoff, cancel, run-stopping errors,
# waits, until:, scope conflicts, a failing store, and starts refused before
# anything is written.
RSpec.describe Smith::Evals::Runner do
  include_context "with an eval run suite"

  def plan_order(trials = 3) = (0...trials).flat_map { |index| (1..12).map { trial_id(format("s-%02d", _1), index) } }
  def stored(run, kind) = eval_store.public_send(kind, scope: eval_scope, eval_run_id: run.eval_run_id)

  it "runs every sample's trial 0, then every sample's trial 1, and so on, sorted by sample id" do
    run_suite(suite)

    expect(started).to eq(plan_order)
  end

  context "when a trial's first attempt meets a retried error" do
    let(:faults) { { trial_id("s-02", 0) => 1 } }

    it "runs its retry in its place in plan order, before the later trials of its index" do
      run_suite(suite)

      expect(started).to eq(plan_order.insert(2, trial_id("s-02", 0)))
    end
  end

  # Design 4.4: pass_at_k and pass_all_k read k trials of a sample, so a
  # sample with fewer counted trials is left out of that result and counted
  # in its samples_uncounted.
  context "with a pass_at_3 scorer and a trial that errors after its retries" do
    let(:faults) { { trial_id("s-02", 1) => 3 } }

    it "writes the summary, leaving the sample with fewer than 3 counted trials out of that result" do
      klass = suite
      klass.scorer(:category_any, version: 1, reduce: "pass_at_3", &method(:category_score))
      run = run_suite(klass)
      result = run.summary["results"].find { _1["scorer"] == "category_any" }

      expect(run.status).to eq(:succeeded)
      expect(stored(run, :each_trial).count).to eq(36)
      expect(result.values_at("reducer", "samples_uncounted", "trials_counted")).to eq(["pass_at_3", 1, 33])
      expect(run.result(:category_any).n).to eq(11)
      expect(schema_errors(run.summary, "summary")).to eq([])
    end
  end

  it "scores a trial whose subject ran out of its transitions by its scorers, on what it had done" do
    klass = with_stubbed_class("SpecEvalLooping", SpecEvalTriage) { max_transitions 1 }
    line = stored(run_suite(suite(workflow: klass, trials: 1)), :each_trial).first

    expect([line["outcome"], line.dig("reason", "code")]).to eq(%w[limit_hit max_transitions])
    expect(line["scores"]["category"]).to include("status" => "scored", "source" => "scorer", "passed" => false)
  end

  describe "a trial's retries" do
    let(:faults) { { trial_id("s-02", 0) => 2, trial_id("s-02", 0, suite_name: "spec.e2e_sleeping") => 2 } }
    let(:waits) { [] }

    before do
      allow_any_instance_of(described_class::Queue).to receive(:put_back).and_wrap_original do |put_back, item|
        waits << (item.not_before - Process.clock_gettime(Process::CLOCK_MONOTONIC)).round
        put_back.call(item.with(not_before: nil))
      end
    end

    it "goes back to the queue at once with the driver's retry_waits :immediate, and after min(30, 2**attempt) " \
       "seconds with :sleep, its latency the final attempt's" do
      run_suite(suite)
      immediate = waits.dup
      waits.clear
      fault_calls.clear
      sleeping = Smith::Evals::Drivers::InProcess.new(retry_waits: :sleep)
      slept = run_suite(suite("SpecEvalSleeping", suite_name: "spec.e2e_sleeping"), driver: sleeping)

      expect(immediate).to eq([0, 0])
      expect(waits).to eq([2, 4])
      line = slept.record.each_trial.find { _1["sample_id"] == "s-02" && _1["trial_index"].zero? }
      expect(line["attempts"].map { _1["outcome"] }).to eq(%w[error error scored])
      expect(line["latency_ms"]).to eq(line["attempts"].last["duration_ms"])
      expect(line["duration_ms"]).to be >= line["attempts"].sum { _1["duration_ms"] }
    end
  end

  context "when a trial's first attempt pays for a call and then fails" do
    let(:faults) { { trial_id("s-02", 0) => 1 } }

    it "keeps every attempt's spend in the line's usage, by model, and the last attempt's steps" do
      klass = with_stubbed_class("SpecEvalLate", Smith::Workflow) do
        initial_state :new
        %i[triaged checked failed].each { state _1 }
        seed_messages { |context| [{ role: :user, content: context[:ticket] }] }
        transition(:classify, from: :new, to: :triaged) { execute :spec_eval_classifier, output_to: :triage }
        transition(:check, from: :triaged, to: :checked) { compute { |_step| SpecEvalFault.call } }
      end
      stub_const("SpecEvalFault", method(:fault!))
      run = run_suite(suite(workflow: klass, trials: 1))
      line = stored(run, :each_trial).find { _1["sample_id"] == "s-02" }
      step_cost = line["steps"].sole["cost_nanos"]

      expect(line["attempts"].map { _1.values_at("outcome", "cost_nanos") })
        .to eq([["error", step_cost], ["scored", step_cost]])
      expect(line["usage"].values_at("cost_nanos", "provider_calls")).to eq([2 * step_cost, 2])
      expect(step_cost).to eq(200_000)
      expect(line["usage"]["by_model"].map { _1.values_at("provider", "provider_calls", "cost_nanos") })
        .to eq([["anthropic", 2, 2 * step_cost]])
      expect(line["usage"]["tokens"]["input"]).to eq(200)
      expect(line["counts"]["agent_attempts"]).to eq(1)
      expect(run.summary["usage"]["cost_nanos"]).to eq(stored(run, :each_trial).sum { _1["usage"]["cost_nanos"] })
    end
  end

  it "keeps no messages when the suite records no content, and says so in its header and lines" do
    run = run_suite(suite(trials: 1, content: false))
    lines = stored(run, :each_trial).to_a

    expect(run.record.header["recording"]["content"]).to be(false)
    expect(lines.flat_map { _1["steps"] }.map { _1["messages"] }.uniq).to eq([nil])
    expect(lines.map { _1["recording"]["gaps"] }.uniq).to eq([["content_off"]])
  end

  context "when the run stops while a trial waits for its retry" do
    let(:faults) { { trial_id("s-01", 0) => 99 } }
    let(:put_back) { Thread::Queue.new }
    let(:hook) do
      lambda do |trial|
        next unless trial == trial_id("s-02", 0)

        waited(put_back)
        raise Smith::AgentRegistryError, "no agent :spec_gone"
      end
    end

    before do
      queue = put_back
      allow_any_instance_of(described_class::Queue).to receive(:put_back).and_wrap_original do |original, item|
        original.call(item).tap { queue << true }
      end
    end

    it "records that trial as it stands, its one attempt kept, and starts no other" do
      sleeping = Smith::Evals::Drivers::InProcess.new(retry_waits: :sleep)
      run = run_suite(suite(concurrency: 2), driver: sleeping)
      lines = stored(run, :each_trial).to_h { [_1["sample_id"], _1] }

      expect(run.status).to eq(:failed)
      expect(lines.keys).to contain_exactly("s-01", "s-02")
      expect(lines["s-01"]["attempts"].map { _1.dig("reason", "code") }).to eq(["host_infrastructure"])
      expect(run.summary["outcomes"]["not_run"]).to eq(34)
    end
  end

  it "carries the caller's attribution to its workers, as on the caller's own thread" do
    run = Smith::Attribution.with(round: 7, branch_key: "outer") { run_suite(suite(trials: 1, concurrency: 2)) }

    expect(stored(run, :each_trial).flat_map { _1["steps"] }.map { _1["position"].values_at("round", "branch_key") })
      .to all(eq([7, "outer"]))
  end

  describe "cancel" do
    let(:second_started) { Thread::Queue.new }
    let(:asked_to_cancel) { Thread::Queue.new }
    let(:cancelled) { [] }
    # s-01 waits for s-02 to start, then asks to cancel; s-02 goes on only
    # once it has, so both are running when the flag is set.
    let(:hook) do
      lambda do |trial|
        if trial == trial_id("s-02", 0)
          second_started << true
          waited(asked_to_cancel)
        elsif trial == trial_id("s-01", 0)
          waited(second_started)
          cancelled << Smith::Evals.cancel(run_id, scope: eval_scope, store: eval_store, reason: "wrong dataset",
                                                   actor: Smith::Evals::Actor.person("usr_1"))
          asked_to_cancel << true
        end
      end
    end

    def run_id = Smith::Evals::Identity.eval_run_id(key: eval_key, scope: eval_scope, suite: "spec.e2e_triage")

    it "stops dispatch, records the trials running, and ends cancelled with who asked" do
      run = run_suite(suite(concurrency: 2))
      summary = run.summary

      expect(cancelled).to eq([:requested])
      expect(run.status).to eq(:cancelled)
      expect(stored(run, :each_trial).map { _1["sample_id"] }).to contain_exactly("s-01", "s-02")
      expect(summary["stop"]).to include("reason" => { "code" => "cancelled", "by" => "operator",
                                                       "detail" => "wrong dataset" },
                                         "actor" => { "kind" => "person", "id" => "usr_1" }, "trial_id" => nil)
      expect(summary["outcomes"]["not_run"]).to eq(34)
      expect(summary["causes"]["not_run"]).to eq("cancelled" => 34)
      expect(summary["complete"]).to be(false)
      expect(EvalsSchema.errors(summary, schema: "summary", strict: true)).to eq([])
    end

    it "is final: called again, a cancelled run runs nothing" do
      klass = suite(concurrency: 2)
      run_suite(klass)
      ran = started.size
      again = run_suite(klass)

      expect([again.status, again.summary["summary_revision"], started.size]).to eq([:cancelled, 1, ran])
    end

    context "when the cancel comes while the last trial runs" do
      let(:hook) do
        lambda do |trial|
          next unless trial == trial_id("s-12", 0)

          Smith::Evals.cancel(run_id, scope: eval_scope, store: eval_store, actor: Smith::Evals::Actor.person("usr_1"))
        end
      end

      it "ends succeeded with no stop, as every planned trial has its line" do
        summary = run_suite(suite(trials: 1)).summary

        expect(summary.values_at("status", "stop", "complete")).to eq(["succeeded", nil, true])
        expect(summary["outcomes"]["not_run"]).to eq(0)
      end
    end
  end

  context "when a trial meets a run-stopping error" do
    let(:hook) { ->(trial) { raise Smith::AgentRegistryError, "no agent :spec_gone" if trial == trial_id("s-03", 0) } }

    it "stops dispatch, records it, and ends failed with its trial" do
      run = run_suite(suite)
      summary = run.summary

      expect(run.status).to eq(:failed)
      expect(summary["stop"]).to include("reason" => include("code" => "definition_error", "by" => "subject"),
                                         "actor" => nil, "trial_id" => trial_id("s-03", 0))
      expect(stored(run, :each_trial).map { _1["sample_id"] }).to eq(%w[s-01 s-02 s-03])
      expect(summary["outcomes"].values_at("error", "not_run")).to eq([1, 33])
      expect(summary["causes"]["not_run"]).to eq("definition_error" => 33)
      expect(EvalsSchema.errors(summary, schema: "summary", strict: true)).to eq([])
    end

    # Probe R-D of the review: a definition error is the subject's, and
    # every trial would meet it, so the run is final; called again it runs
    # nothing (a run a provider, the store or the ledger stopped goes on).
    it "is returned as it is when called again, running nothing" do
      klass = suite
      first = run_suite(klass)
      again = run_suite(klass)

      expect([again.status, again.summary["summary_revision"]]).to eq([:failed, 1])
      expect(stored(again, :each_trial).count).to eq(stored(first, :each_trial).count)
      expect(started.count(trial_id("s-04", 0))).to eq(0)
    end
  end

  # A trial the host's budget ledger refused, or that met an error that
  # stops every trial, did not run: the run starts no more trials, keeps a
  # line for it only when a request of it left, and called again once the
  # cause is gone, runs every trial without a final line, each once.
  describe "a run the budget ledger or a run-stopping error stopped" do
    let(:admit) { 3 }
    let(:ledger) { TuningRunSuite::Ledger.new(admit) }

    def ledgered(name, calls:)
      held = ledger
      with_stubbed_class(name, Smith::Workflow) do
        budget_ledger { |_scope| held }
        initial_state :new
        %i[triaged checked failed].each { state _1 }
        seed_messages { |context| [{ role: :user, content: context[:ticket] }] }
        transition(:classify, from: :new, to: :triaged) do
          execute :spec_eval_classifier, output_to: :triage
          on_failure :fail
        end
        next if calls == 1

        transition(:check, from: :triaged, to: :checked) do
          execute :spec_eval_classifier, output_to: :checked
          on_failure :fail
        end
      end
    end

    def lines(run) = stored(run, :each_trial).to_a

    it "stops at the first refusal, incomplete, and finishes when called again, running no trial twice" do
      klass = suite(workflow: ledgered("SpecEvalLedgered", calls: 1), trials: 1)
      stopped = run_suite(klass)
      stopped_lines = lines(stopped)
      ledger.instance_variable_set(:@admit, nil)
      finished = run_suite(klass)

      expect(stopped.status).to eq(:incomplete)
      expect(stopped.summary["stop"]["reason"].values_at("code", "by")).to eq(%w[ledger_refused infrastructure])
      expect(stopped.summary["stop"]["trial_id"]).to eq(trial_id("s-04", 0))
      expect(stopped_lines.map { _1["sample_id"] }).to eq(%w[s-01 s-02 s-03])
      expect(stopped.summary["outcomes"]["not_run"]).to eq(9)
      expect([finished.status, finished.summary["summary_revision"]]).to eq([:succeeded, 2])
      expect(lines(finished).first(3)).to eq(stopped_lines)
      expect(lines(finished).map { _1["trial_id"] }.tally.values.uniq).to eq([1])
      expect(stored(finished, :each_segment).count).to eq(2)
    end

    it "keeps a line for a refused trial a request of which left, and writes it again above that revision" do
      klass = suite(workflow: ledgered("SpecEvalLedgeredTwice", calls: 2), trials: 1)
      ledger.instance_variable_set(:@admit, 5)
      stopped = run_suite(klass)
      refused = lines(stopped).last
      ledger.instance_variable_set(:@admit, nil)
      finished = run_suite(klass)
      again = lines(finished).select { _1["trial_id"] == refused["trial_id"] }

      expect(refused.values_at("sample_id", "outcome", "trial_revision")).to eq(["s-03", "not_run", 1])
      expect(refused["usage"].values_at("provider_calls", "cost_complete")).to eq([1, true])
      expect(refused["scores"]).to eq({})
      expect(again.map { _1.values_at("outcome", "trial_revision") }).to eq([["not_run", 1], ["scored", 2]])
      expect(finished.record.each_trial.map { _1["outcome"] }).not_to include("not_run")
      expect(finished.summary["usage"]["provider_calls"]).to eq(lines(finished).sum { _1["usage"]["provider_calls"] })
      expect(lines(finished).map { schema_errors(_1, "trial") }.uniq).to eq([[]])
    end

    it "finishes a run a missing key stopped once the key is found, the trials that ran not run again" do
      broken = [true]
      stub_const("SpecEvalBroken", broken)
      klass = suite(trials: 1)
      allow(self).to receive(:hook).and_return(lambda do |trial|
        next unless SpecEvalBroken.first && trial == trial_id("s-06", 0)

        raise Smith::ProviderCredentialsMissing.new("no key", provider: :anthropic)
      end)
      stopped = run_suite(klass)
      broken[0] = false
      finished = run_suite(klass)

      expect(stopped.status).to eq(:failed)
      expect([finished.status, finished.summary["summary_revision"]]).to eq([:succeeded, 2])
      expect(started.tally.select { |_trial, count| count > 1 }.keys).to eq([trial_id("s-06", 0)])
      expect(lines(finished).size).to eq(12)
    end
  end

  context "when no key is found for the provider" do
    let(:hook) do
      lambda do |_trial|
        raise Smith::ProviderCredentialsMissing.new("anthropic: no key sk-live-123 for ten_1", provider: :anthropic)
      end
    end

    # The trial did not run and sent nothing, so it has no line: the
    # summary's stop names it, and called again once a key is found, the
    # run goes on.
    it "stops the run on its first trial, writing nothing of the error's own words" do
      run = run_suite(suite)

      expect(run.status).to eq(:failed)
      expect(run.summary["stop"]["reason"].values_at("code", "by")).to eq(%w[credentials_missing infrastructure])
      expect(run.summary["stop"]["trial_id"]).to eq(trial_id("s-01", 0))
      expect(stored(run, :each_trial).to_a).to eq([])
      expect(JSON.generate(run.summary)).not_to include("sk-live")
    end
  end

  it "records a subject that waits as error subject_waited, not retried, and goes on" do
    klass = with_stubbed_class("SpecEvalAwaiting", Smith::Workflow) do
      initial_state :new
      state :triaged
      state :approved
      state :failed
      seed_messages { |context| [{ role: :user, content: context[:ticket] }] }
      transition(:classify, from: :new, to: :triaged) { execute :spec_eval_classifier, output_to: :triage }
      transition :approve, from: :triaged, to: :approved do
        await :approval, into: :approval, timeout: 3_600
        on_failure :fail
      end
    end
    waited = run_suite(suite(workflow: klass, trials: 1))
    stopped = Smith::Evals.run(suite("SpecEvalUntil", workflow: klass, trials: 1, until: :triaged,
                                                      suite_name: "spec.e2e_until"),
                               scope: eval_scope, store: eval_store)

    expect(waited.status).to eq(:succeeded)
    expect(waited.summary["causes"]["error"]).to eq("subject_waited" => 11)
    line = stored(waited, :each_trial).first
    expect(line.values_at("outcome", "subject")).to eq(["error", { "final_state" => "triaged", "ended" => "waiting",
                                                                   "waiting" => "await" }])
    expect(line["attempts"].size).to eq(1)
    expect(stopped.summary["outcomes"].values_at("scored", "unscored", "subject_failed")).to eq([10, 1, 1])
    expect(stored(stopped, :each_trial).first["subject"]["ended"]).to eq("until")
  end

  it "ends a run whose input mapping sets a trusted scope key to another value failed, with scope_conflict" do
    klass = with_stubbed_class("SpecEvalScoped", SpecEvalTriage) { budget_ledger(:tenant) { |_scope| nil } }
    run = run_suite(suite(workflow: klass, input: ->(s) { { ticket: s.input[:text], tenant: "ten_2" } }))

    expect(run.status).to eq(:failed)
    expect(run.summary["stop"]["reason"]).to include("code" => "scope_conflict", "by" => "eval_run")
    expect(stored(run, :each_trial).count).to eq(1)
    expect(Smith::Testing.stub_for(SpecEvalClassifier).calls).to eq([])
    expect(run_suite(suite(workflow: klass, input: ->(s) { { ticket: s.input[:text], tenant: "ten_2" } }))
             .summary["summary_revision"]).to eq(1)
  end

  it "ends failed with store_error when the store fails mid-run, the summary still written" do
    calls = 0
    allow(eval_store).to receive(:append_trial).and_wrap_original do |append, **args|
      calls += 1
      raise Smith::Evals::StoreError.new("disk full", operation: :append_trial) if calls == 3

      append.call(**args)
    end
    run = run_suite(suite)

    expect(run.status).to eq(:failed)
    expect(run.summary["stop"]["reason"]).to include("code" => "store_error", "by" => "infrastructure")
    expect(run.summary["outcomes"]["not_run"]).to eq(34)
  end

  it "ends failed with store_error when the store fails reading the cancel flag, naming no trial" do
    reads = 0
    allow(eval_store).to receive(:cancel_request).and_wrap_original do |read, **args|
      reads += 1
      raise Smith::Evals::StoreError.new("disk gone", operation: :cancel_request) if reads == 5

      read.call(**args)
    end
    run = run_suite(suite(trials: 1))

    expect(run.status).to eq(:failed)
    expect(run.summary["stop"]).to include("reason" => { "code" => "store_error", "by" => "infrastructure",
                                                         "detail" => "the store failed in cancel_request" },
                                           "trial_id" => nil)
    expect(stored(run, :each_trial).count).to eq(4)
    expect(run.summary["outcomes"]["not_run"]).to eq(8)
    expect(schema_errors(run.summary, "summary")).to eq([])
  end

  # A worker took s-02 just before another worker's trial stopped the run:
  # s-02's worker reads the cancel flag, s-01 stops the run meanwhile.
  context "when the run stops while a worker is taking its next trial" do
    let(:taken) { {} }
    let(:checking) { Thread::Queue.new }
    let(:halted) { Thread::Queue.new }
    let(:hook) do
      lambda do |trial|
        next unless trial == trial_id("s-01", 0)

        waited(checking)
        raise Smith::AgentRegistryError, "no agent :spec_gone"
      end
    end

    before do
      allow_any_instance_of(described_class::Queue).to receive(:take).and_wrap_original do |take|
        take.call.tap { taken[Thread.current] = _1 }
      end
      allow_any_instance_of(described_class::Queue).to receive(:halt).and_wrap_original do |halt, stop|
        halt.call(stop).tap { halted << true }
      end
      allow(eval_store).to receive(:cancel_request).and_wrap_original do |read, **args|
        if taken[Thread.current]&.sample&.id == "s-02"
          checking << true
          waited(halted)
        end
        read.call(**args)
      end
    end

    it "starts no trial it took before the stop" do
      run = run_suite(suite(concurrency: 2))

      expect(started).to eq([trial_id("s-01", 0)])
      expect(stored(run, :each_trial).map { _1["sample_id"] }).to eq(["s-01"])
      expect(run.summary["outcomes"]["not_run"]).to eq(35)
    end
  end

  context "when its caller is interrupted while a trial runs" do
    let(:running) { Thread::Queue.new }
    let(:halted) { Thread::Queue.new }
    let(:go) { Thread::Queue.new }
    let(:hook) do
      lambda do |trial|
        next unless trial == trial_id("s-02", 0)

        running << true
        waited(go)
      end
    end

    before do
      stub_const("SpecEvalInterrupted", Class.new(StandardError))
      allow_any_instance_of(described_class::Queue).to receive(:halt).and_wrap_original do |halt, stop|
        halt.call(stop).tap { halted << true }
      end
    end

    it "stops its workers and waits for the running trial's line before it lets go of the lease" do
      runner = Thread.new { run_suite(suite(trials: 1)) }
      runner.report_on_exception = false
      waited(running)
      runner.raise(SpecEvalInterrupted, "timed out")
      waited(halted)
      go << true

      expect { runner.join(10) }.to raise_error(SpecEvalInterrupted)
      expect(started).to eq([trial_id("s-01", 0), trial_id("s-02", 0)])
      lines = eval_store.each_trial(scope: eval_scope, eval_run_id: run_id).map { _1["sample_id"] }
      expect(lines).to eq(%w[s-01 s-02])
      expect(eval_store.read_summary(scope: eval_scope, eval_run_id: run_id)).to be_nil
      eval_store.acquire_lease(scope: eval_scope, eval_run_id: run_id).release
    end

    def run_id = Smith::Evals::Identity.eval_run_id(key: eval_key, scope: eval_scope, suite: "spec.e2e_triage")
  end

  # The header names the subject's definition: a workflow's by its class's
  # digest, a host driver's program (no workflow) by null.
  describe "the header's definition_digest" do
    let(:digest) { Digest::SHA256.hexdigest("spec-eval-triage-definition") }

    it "holds a workflow subject's digest, and null for a host driver's non-workflow subject" do
      digest = self.digest
      triage = with_stubbed_class("SpecEvalDigested", SpecEvalTriage) { definition_digest digest }
      program = with_stubbed_class("SpecEvalHostProgram", Class.new)
      hosted = Class.new(Smith::Evals::Driver) do
        def run(_trial, _context)
          Smith::Evals::SubjectResult.new(ended: :terminal, final_state: "done", failed: false, output: nil,
                                          state: { triage: { category: "other" } }, error: nil, waiting: nil,
                                          usage_entries: [], child_runs: 0, duration_ms: 1)
        end
      end

      own = run_suite(suite(workflow: triage, trials: 1))
      host = run_suite(suite("SpecEvalHostSuite", workflow: program, trials: 1, suite_name: "spec.host_header"),
                       driver: hosted.new)

      expect([own, host].map { _1.record.header.dig("subject", "definition_digest") }).to eq([digest, nil])
    end
  end

  describe "a start" do
    def nothing_written = eval_store.list_records(scope: eval_scope)["records"]

    it "is refused before anything is written for a driver that is not in process" do
      across = Class.new(Smith::Evals::Driver) { def self.form = :across_processes }

      expect { run_suite(suite, driver: across.new) }.to raise_error(Smith::Evals::DriverUnsupported)
      expect(nothing_written).to eq([])
    end

    # A host driver runs any subject; Smith's own runs a workflow.
    it "is refused before anything is written for a subject Smith's driver cannot run" do
      program = with_stubbed_class("SpecEvalProgram", Class.new)

      expect { run_suite(suite(workflow: program)) }
        .to raise_error(Smith::Evals::SubjectNotReady, /SpecEvalProgram is no Smith::Workflow/)
      expect(nothing_written).to eq([])
    end

    it "is refused before anything is written for a subject that is not ready" do
      broken = with_stubbed_class("SpecEvalBroken", SpecEvalTriage)
      readiness = instance_double(Smith::Workflow::Graph::RuntimeReadinessReport, status: :not_ready,
                                                                                  errors: [double(code: :unreachable)])
      allow(broken).to receive(:runtime_readiness).and_return(readiness)

      expect { run_suite(suite(workflow: broken)) }
        .to raise_error(Smith::Evals::SubjectNotReady, "SpecEvalBroken is not ready to run (unreachable): see its " \
                                                       "runtime_readiness")
      expect(nothing_written).to eq([])
    end

    it "refuses an id that is no eval run id before it reaches the store, whatever the store checks" do
      allow(eval_store).to receive(:create_record).and_call_original

      expect { Smith::Evals.run(suite, scope: eval_scope, eval_run_id: "er_X", store: eval_store) }
        .to raise_error(ArgumentError, "an eval run id is er_ and 32 lowercase hex digits")
      expect(eval_store).not_to have_received(:create_record)
    end

    it "is refused before anything is written for an invalid suite" do
      expect { run_suite(suite(trials: 0)) }.to raise_error(Smith::Evals::SuiteInvalid)
      expect(nothing_written).to eq([])
    end

    # 12 samples at 100 resamples is 1,200 resamples of a sample: one past
    # the bound, then exactly at it. Only pass_at_k and pass_all_k bootstrap.
    it "is refused before anything is written when a pass_at_k bootstrap over its samples passes its work bound" do
      klass = suite(trials: 1)
      klass.statistics(bootstrap_resamples: 100)
      klass.scorer(:category_any, version: 1, reduce: "pass_at_1", &method(:category_score))
      plain = suite("SpecEvalPlain", trials: 1, suite_name: "spec.e2e_plain")
      plain.statistics(bootstrap_resamples: 100)

      stub_const("Smith::Evals::Statistics::MAX_BOOTSTRAP_WORK", 1_199)
      expect { run_suite(klass) }.to raise_error(Smith::Evals::SuiteInvalid, %r{/statistics/bootstrap_resamples: })
      expect(nothing_written).to eq([])
      expect(run_suite(plain).status).to eq(:succeeded)
      stub_const("Smith::Evals::Statistics::MAX_BOOTSTRAP_WORK", 1_200)
      expect(run_suite(klass).status).to eq(:succeeded)
    end
  end
end
