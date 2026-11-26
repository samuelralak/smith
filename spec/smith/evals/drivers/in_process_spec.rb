# frozen_string_literal: true

require "open3"
require "smith/evals"
require "smith/testing"

# The in-process driver (slice-1a design, 4.9 and 5.2): it builds the
# subject from the sample, runs it inside the trial, and returns what it
# ended as (SubjectResult), the eval scope's declared keys in its context.
RSpec.describe Smith::Evals::Drivers::InProcess do
  include_context "with an eval trial"

  let(:testing) { Smith::Testing }
  let(:driver) { described_class.new }

  around do |example|
    unstubbed = testing.unstubbed
    testing.unstubbed = :refuse
    example.run
  ensure
    testing.unstubbed = unstubbed
    testing.reset!
  end

  def subject_of(workflow, input: ->(sample) { { ticket: sample.input[:text] } }, **options)
    Smith::Evals::Subject.new(workflow:, input:, **options)
  end

  def trial_for(subject, **options)
    Smith::Evals::TrialSpec.for(eval_run_id:, scope: eval_scope, sample:, trial_index: 0, subject:, **options)
  end

  def driven(subject, recorder: nil, **options)
    trial = trial_for(subject, **options)
    recorder ||= Smith::Evals::Recorder.new(trial.trial_id)
    result = Smith::Evals::Recording.attach(recorder) { driver.run(trial, trial.context) }
    [result, recorder]
  end

  def triage(name, &)
    with_stubbed_class(name, workflow_class) do
      initial_state :idle
      state :failed
      seed_messages { |context| [{ role: :user, content: "Ticket: #{context[:ticket]}" }] }
      transition :ask, from: :idle, to: :done do
        execute :spec_ledger_agent, output_to: :triage
        on_failure :fail
      end
      class_exec(&) if block_given?
    end
  end

  before do
    agent("SpecDriverAgent")
    testing.stub_agent(:spec_ledger_agent, outputs: ->(request) { "Read: #{request.last_user}" })
  end

  describe "the driver interface" do
    it "is in process, runs as many trials at once as it says, and isolates trials only when told how" do
      base = Smith::Evals::Driver.new
      around = ->(trial, &run) { [:isolated, trial, run.call] }
      isolating = described_class.new(max_concurrency: 2, around_trial: around)

      expect([Smith::Evals::Driver.form, base.max_concurrency, base.isolation, base.around_trial(:t) { :ran }])
        .to eq([:in_process, 1, :none, :ran])
      expect { base.run(:trial, :context) }.to raise_error(NotImplementedError, /run\(trial, context\)/)
      expect([described_class.form, driver.max_concurrency, driver.isolation, driver.around_trial(:t) { :ran }])
        .to eq([:in_process, 8, :none, :ran])
      expect([isolating.max_concurrency, isolating.isolation, isolating.around_trial(:t) { :ran }])
        .to eq([2, :around_trial, %i[isolated t ran]])
      [{ max_concurrency: 0 }, { around_trial: :rollback }, { retry_waits: :later }].each do |options|
        expect { described_class.new(**options) }.to raise_error(ArgumentError), options.inspect
      end
    end

    # Design 5.7: the backoff before a trial's retry, and a durable retry's
    # wait (5.2), except in a test suite. A child process loads evals
    # without smith/testing, as a host's production code does.
    it "waits before retries by default, and not by default under Smith::Testing" do
      script = <<~RUBY
        require "smith/evals"
        drivers = [Smith::Evals::Drivers::InProcess.new, Smith::Evals::Driver.new,
                   Smith::Evals::Drivers::InProcess.new(retry_waits: :immediate)]
        print drivers.map(&:retry_waits).join(" ")
      RUBY
      waits, errors, status = Open3.capture3(RbConfig.ruby, "-I", File.expand_path("../../../../lib", __dir__),
                                             "-e", script)

      expect([waits, errors, status.success?]).to eq(["sleep sleep immediate", "", true])
      expect(described_class.new.retry_waits).to eq(:immediate)
    end
  end

  # What the driver is handed for a trial (design 5.1 and 5.3).
  describe "the trial spec and its context" do
    it "seeds a trial from the first 8 hex digits of its id, after its prefix" do
      trial = trial_for(nil)

      expect(trial.trial_id).to match(/\Atr_\h{32}\z/)
      expect(trial.seed).to eq(Integer(trial.trial_id[3, 8], 16))
      expect(trial.seed).to eq(trial_for(nil, attempt: 2).seed)
      expect(Smith::Evals::TrialSpec.for(eval_run_id:, scope: eval_scope, sample:, trial_index: 1, subject: nil).seed)
        .not_to eq(trial.seed)
    end

    # Slice 3a saves this form with every run under a trial.
    it "gives its context's JSON form, the candidate only when there is one" do
      plain = trial_for(nil).context
      chosen = plain.with(candidate_id: "cand_1")

      expect(plain.to_h).to eq(
        "format" => "smith.evals.trial_context", "format_version" => 1, "trial_id" => plain.trial_id,
        "eval_run_id" => eval_run_id, "scope" => { "tenant" => "ten_1" }, "sample_id" => "t-1", "trial_index" => 0
      )
      expect(chosen.to_h).to eq(plain.to_h.merge("candidate_id" => "cand_1"))
      expect(JSON.parse(JSON.generate(plain.to_h))).to eq(plain.to_h)
    end
  end

  describe "#run" do
    it "runs the subject on the sample's input inside the trial, and returns how it ended with the kept keys" do
      klass = triage("SpecDriverTriage")
      result, recorder = driven(subject_of(klass, keep: %i[triage]))

      expect(result).to be_a(Smith::Evals::SubjectResult).and(be_frozen)
      expect(result.to_h.except(:usage_entries, :duration_ms)).to eq(
        ended: :terminal, final_state: "done", failed: false, output: "Read: Ticket: My parcel never came.",
        state: { triage: "Read: Ticket: My parcel never came." }, error: nil, waiting: nil, child_runs: 0
      )
      expect(result.usage_entries.map(&:attempt_id)).to eq(recorder.steps.map { _1["attempt_id"] })
      expect(result.duration_ms).to be_a(Integer).and(be >= 0)
    end

    it "writes the eval scope's values for the keys the subject declares trusted into its context" do
      scopes = []
      seen = ledger
      credentials = Smith::ProviderCredentials.new(anthropic: { api_key: "sk-spec-driver-key-0123456789",
                                                                api_base: server.url })
      klass = triage("SpecDriverScoped") do
        budget_ledger(:tenant) do |scope|
          scopes << [:ledger, scope]
          seen
        end
        provider_credentials(:project) do |scope|
          scopes << [:credentials, scope]
          credentials
        end
      end
      scope = Smith::Scope.build(tenant: "ten_1", project: "prj_7")
      trial = Smith::Evals::TrialSpec.for(eval_run_id:, scope:, sample:, trial_index: 0,
                                          subject: subject_of(klass, input: lambda { |_s|
                                            { ticket: "x", tenant: "ten_1" }
                                          }))

      expect(driver.run(trial, trial.context).final_state).to eq("done")
      expect(scopes).to contain_exactly([:ledger, { tenant: "ten_1" }], [:credentials, { "project" => "prj_7" }])
    end

    it "refuses a mapping that sets a declared scope key to another value, before anything runs" do
      klass = triage("SpecDriverConflict") { budget_ledger(:tenant) { |_scope| nil } }
      conflicting = subject_of(klass, input: ->(_s) { { ticket: "x", "tenant" => "ten_2" } })
      trial = trial_for(conflicting)

      expect { driver.run(trial, trial.context) }
        .to raise_error(Smith::Evals::ScopeConflict,
                        "the input mapping sets tenant, a scope key SpecDriverConflict trusts, to another value " \
                        "than the eval run's scope")
      expect(testing.stub_for(SpecDriverAgent).calls).to eq([])
    end

    it "lets the driver's own failures out: a mapping that raises or gives no Hash" do
      klass = triage("SpecDriverMapping")
      [->(_s) { raise IOError, "the mapping's host broke" }, ->(_s) { "not a context" }].each do |input|
        trial = trial_for(subject_of(klass, input:))
        expect { driver.run(trial, trial.context) }.to raise_error(StandardError) do |error|
          expect(error).not_to be_a(Smith::Evals::ScopeConflict)
        end
      end
      expect(testing.stub_for(SpecDriverAgent).calls).to eq([])
    end

    it "returns a run that raised as raised, with the error, and a failed run with its step's error" do
      raising = with_stubbed_class("SpecDriverRaising", workflow_class) do
        initial_state :idle
        transition(:boom, from: :idle, to: :done) { compute { |_step| raise IOError, "the host's disk is full" } }
      end
      failing = triage("SpecDriverFailing")
      testing.stub_agent(:spec_ledger_agent, outputs: "x", stop_reason: "max_tokens")

      raised, = driven(subject_of(raising))
      failed, = driven(subject_of(failing))
      expect([raised.ended, raised.error.class, raised.final_state]).to eq([:raised, IOError, "idle"])
      expect([failed.ended, failed.failed, failed.error.class, failed.final_state])
        .to eq([:terminal, true, Smith::OutputTruncated, "failed"])
    end

    # The driver advances the run itself, as run! does, so a later change
    # to run! must reach it too: on the same input it ends as run! ends.
    it "ends a run as a plain run! ends it: its state, output, error, kept keys and usage" do
      answered = triage("SpecDriverLikeRun")
      failing = triage("SpecDriverLikeRunFailing")
      usage = ->(entries) { entries.map { [_1.input_tokens, _1.output_tokens, _1.attempt_kind] } }
      pairs = [[answered, "end_turn"], [failing, "max_tokens"]].map do |klass, stop|
        testing.stub_agent(:spec_ledger_agent, outputs: ->(request) { "Read: #{request.last_user}" },
                                               stop_reason: stop)
        result, = driven(subject_of(klass, keep: %i[triage]))
        plain = klass.new(context: { ticket: "My parcel never came." })
        run = plain.run!
        kept = run.context.slice(:triage)
        [[result.final_state, result.failed, result.output, result.error&.class, result.state,
          usage.call(result.usage_entries)],
         [run.state.to_s, run.failed?, run.output, run.last_error&.class, kept.empty? ? nil : kept,
          usage.call(plain.usage_entries)]]
      end

      pairs.each { |driver, plain| expect(driver).to eq(plain) }
      expect(pairs.map { _1.first.first(2) }).to eq([["done", false], ["failed", true]])
    end

    # The driver's own code after the run is not the subject's: a failure
    # there leaves `run`, for the runner's driver_error.
    it "lets a failure in building the result out, rather than reading it as the subject's" do
      allow(Smith::Evals::SubjectResult).to receive(:from_workflow).and_raise(NoMethodError, "the driver's bug")

      expect { driven(subject_of(triage("SpecDriverBuggy"))) }.to raise_error(NoMethodError, "the driver's bug")
    end

    it "ends a durable retry's wait at once and runs on, or sleeps until it is due, as by default outside tests" do
      klass = with_stubbed_class("SpecDriverRetry", workflow_class) do
        initial_state :idle
        state :failed
        seed_messages { |_context| [{ role: :user, content: "Answer." }] }
        transition :ask, from: :idle, to: :done do
          execute :spec_ledger_agent
          retry_on Smith::AgentError, attempts: 2, backoff: 30, durable: true
          on_failure :fail
        end
      end
      calls = 0
      testing.stub_agent(:spec_ledger_agent, outputs: lambda { |_request|
        raise Smith::AgentError, "overloaded" if (calls += 1) == 1

        "Second time."
      })

      result, = driven(subject_of(klass))
      expect([result.ended, result.output, calls]).to eq([:terminal, "Second time.", 2])

      calls = 0
      sleeping = described_class.new(retry_waits: :sleep)
      allow(sleeping).to receive(:sleep)
      trial = trial_for(subject_of(klass))
      expect(sleeping.run(trial, trial.context).output).to eq("Second time.")
      expect(sleeping).to have_received(:sleep).with(a_value_between(29, 31))

      # Given no retry_waits, outside Smith::Testing (:sleep, as the child
      # process in "waits before retries by default" shows).
      calls = 0
      defaulted = described_class.new
      allow(defaulted).to receive_messages(retry_waits: :sleep, sleep: nil)
      trial = trial_for(subject_of(klass))
      expect(defaulted.run(trial, trial.context).output).to eq("Second time.")
      expect(defaulted).to have_received(:sleep).with(a_value_between(29, 31))
    end

    it "stops at the until state, a step at a time, and reports a run that waits as waiting" do
      klass = with_stubbed_class("SpecDriverStaged", workflow_class) do
        initial_state :idle
        state :failed
        seed_messages { |_context| [{ role: :user, content: "Draft it." }] }
        transition(:draft, from: :idle, to: :drafted) { execute :spec_ledger_agent, output_to: :draft }
        transition :approve, from: :drafted, to: :approved do
          await :approval, into: :approval, timeout: 3_600
          on_failure :fail
        end
        transition(:send_note, from: :approved, to: :done) { execute :spec_ledger_agent }
      end

      staged, recorder = driven(subject_of(klass, keep: %i[draft], until: :drafted))
      waited, = driven(subject_of(klass))
      at_wait, = driven(subject_of(klass, until: :drafted))
      expect([staged.ended, staged.final_state, staged.state, recorder.steps.length])
        .to eq([:until, "drafted", { draft: "Read: Draft it." }, 1])
      expect([waited.ended, waited.waiting, waited.final_state]).to eq([:waiting, :await, "drafted"])
      expect(at_wait.ended).to eq(:until)
    end

    it "gives an until run's output as the last step that gave one" do
      testing.stub_agent(:spec_ledger_agent, outputs: ->(request) { "Step #{request.number}." })
      klass = with_stubbed_class("SpecDriverTwoSteps", workflow_class) do
        initial_state :idle
        state :failed
        seed_messages { |_context| [{ role: :user, content: "Go on." }] }
        transition(:first, from: :idle, to: :one) { execute :spec_ledger_agent }
        transition(:second, from: :one, to: :two) { execute :spec_ledger_agent }
        transition(:third, from: :two, to: :done) { execute :spec_ledger_agent }
      end

      result, = driven(subject_of(klass, until: :two))
      expect([result.ended, result.final_state, result.output]).to eq([:until, "two", "Step 2."])
    end

    it "counts the child runs the inline launcher ran apart from the trial, which the recorder marks a gap" do
      Smith.config.run_launcher = Smith::Launchers::Inline.new
      child = triage("SpecDriverChild")
      parent = with_stubbed_class("SpecDriverParent", workflow_class) do
        initial_state :idle
        state :failed
        transition :delegate, from: :idle, to: :done do
          call child, input: ->(context) { { ticket: context[:ticket] } }, timeout: 60, into: :child
          on_failure :fail
        end
      end

      result, recorder = driven(subject_of(parent))
      expect([result.ended, result.child_runs, recorder.steps]).to eq([:terminal, 1, []])
      expect(testing.stub_for(SpecDriverAgent).calls.length).to eq(1)
      expect(recorder.recording(result)).to include("complete" => false, "gaps" => ["child_runs_not_followed"])
    end

    def delegating(name, child, after: ->(_step) { "done" })
      with_stubbed_class(name, workflow_class) do
        initial_state :idle
        state :failed
        transition(:note, from: :idle, to: :noted) { compute { |_step| "noted" } }
        transition :delegate, from: :noted, to: :delegated do
          call child, input: ->(context) { { ticket: context[:ticket] } }, timeout: 60, into: :child
          on_failure :fail
        end
        transition(:finish, from: :delegated, to: :done) { compute(&after) }
      end
    end

    # A host's launcher that runs children on the trial's own thread keeps
    # the trial's attribution: their steps are recorded, not a gap.
    it "counts only the child-run steps, and only those Smith's inline launcher ran" do
      Smith.config.run_launcher = Smith::Launchers::Inline.new
      inline, = driven(subject_of(delegating("SpecDriverCounted", triage("SpecDriverCountedChild"))))
      Smith.config.run_launcher = Class.new do
        def inline? = true
        def launch(children:, **) = children.map { Smith::ChildRun.result(ref: _1.ref, run_result: _1.build.run!) }
      end.new
      hosted, recorder = driven(subject_of(delegating("SpecDriverHosted", triage("SpecDriverHostedChild"))))

      expect([inline.ended, inline.child_runs]).to eq([:terminal, 1])
      expect([hosted.ended, hosted.child_runs, recorder.steps.length]).to eq([:terminal, 0, 1])
      expect(recorder.recording(hosted)).to include("complete" => true, "gaps" => [])
    end

    # A run that raises after a child-run step still ran it: the recorder
    # did not follow its child, so the record is not whole.
    it "keeps the child runs a run counted before it raised, so the recorder marks the gap" do
      Smith.config.run_launcher = Smith::Launchers::Inline.new
      boom = ->(_step) { raise Smith::MaxTransitionsExceeded, "boom" }
      result, recorder = driven(subject_of(delegating("SpecDriverRaisedAfter", triage("SpecDriverRaisedChild"),
                                                      after: boom)))

      expect([result.ended, result.error.class, result.child_runs]).to eq([:raised, Smith::MaxTransitionsExceeded, 1])
      expect(recorder.recording(result)).to include("complete" => false, "gaps" => ["child_runs_not_followed"])
    end

    it "builds a variant's workflow from the subject's variants hook" do
      plain = triage("SpecDriverPlain")
      other = triage("SpecDriverOther")
      subject = subject_of(plain, variants: ->(variant) { variant == :other ? other : plain })

      expect([subject.workflow_for(nil), subject.workflow_for(:other)]).to eq([plain, other])
      result, = driven(subject, variant: :other)
      expect(result.final_state).to eq("done")
    end
  end

  # What a scorer reads, built outside the trial from what the driver
  # returned and the recorder kept (design 4.8).
  describe "the trial a scorer reads" do
    it "holds the kept state, output, steps and tool calls, and a failed subject's error" do
      stub_const("SpecDriverLookup", Class.new(Smith::Tool) do
        param :query, type: :string, required: true
        define_method(:perform) { |query:| "#{query} opens at 8" }
      end)
      agent("SpecDriverToolAgent") { tools SpecDriverLookup }
      testing.stub_agent(:spec_ledger_agent, outputs: lambda { |request|
        request.round == 1 ? testing.tool_call(SpecDriverLookup, query: "clinic") : "Open at 8."
      })
      trial = trial_for(subject_of(triage("SpecDriverRead"), keep: %i[triage]))
      recorder = Smith::Evals::Recorder.new(trial.trial_id)
      result = Smith::Evals::Recording.attach(recorder) { driver.run(trial, trial.context) }
      outcome = Smith::Evals::Outcomes.classify(result, steps: recorder.steps)
      read = Smith::Evals::Trial.for(trial, result, outcome, recorder)

      expect(read.to_h.except(:steps, :usage, :duration_ms)).to eq(
        id: trial.trial_id, index: 0, sample_id: "t-1", outcome: :answered, state: { triage: "Open at 8." },
        output: "Open at 8.", final_state: :done, failure: nil,
        tool_calls: [{ name: "spec_driver_lookup", arguments: { "query" => "clinic" } }]
      )
      expect(read.steps).to eq(recorder.steps)
      expect(read.usage).to eq(tokens: recorder.usage["tokens"], cost_nanos: recorder.usage["cost_nanos"],
                               cost_complete: true)

      testing.stub_agent(:spec_ledger_agent, outputs: "Cut", stop_reason: "max_tokens")
      cut = Smith::Evals::Recording.attach(Smith::Evals::Recorder.new(trial.trial_id)) do
        driver.run(trial, trial.context)
      end
      failed = Smith::Evals::Trial.for(trial, cut, Smith::Evals::Outcomes.classify(cut, steps: []), recorder)
      expect(failed.failure).to match(class: "Smith::OutputTruncated", family: "output_failure",
                                      message: a_string_including("cut off at its output limit"),
                                      reason: "output_truncated")
      expect(failed.state).to eq({})
    end
  end
end
