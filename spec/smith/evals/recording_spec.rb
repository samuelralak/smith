# frozen_string_literal: true

require "smith/evals"
require "smith/testing"

# Recording, the observer `require "smith/evals"` installs, and
# Smith::Evals.under (slice-1a design, 4.7 and 5.4): each attempt reaches
# the recorder attached for its own trial, and no other.
RSpec.describe Smith::Evals::Recording do
  include_context "with an eval trial"

  let(:testing) { Smith::Testing }

  around do |example|
    example.run
  ensure
    testing.reset!
  end

  before do
    agent("SpecRoutedAgent")
    testing.stub_agent(:spec_ledger_agent, outputs: ->(request) { "Answer #{request.number}." })
  end

  def spec_for(sample_id)
    Smith::Evals::TrialSpec.for(eval_run_id:, scope: eval_scope, trial_index: 0, subject: nil,
                                sample: Smith::Evals::Sample.new({ "id" => sample_id, "input" => {} }, split: :dev))
  end

  def attempt_ids(run) = run.usage_entries.map(&:attempt_id)

  it "is the attempt observer smith/evals installs" do
    expect(Smith::AttemptObservation.observer).to be(described_class)
  end

  it "hands each attempt to the recorder attached for its trial, with two trials running at once" do
    klass = asking("SpecRoutedWorkflow")
    trials = %w[t-1 t-2].map { spec_for(_1) }
    started = Queue.new
    go = Queue.new
    runs = trials.map do |trial|
      recorder = Smith::Evals::Recorder.new(trial.trial_id)
      thread = Thread.new do
        described_class.attach(recorder) do
          Smith::Evals.under(trial.context) do
            started << true
            go.pop(timeout: 5)
            Array.new(2) { klass.new(context: {}).run! }
          end
        end
      end
      [recorder, thread]
    end
    2.times { started.pop(timeout: 5) }
    2.times { go << true }

    runs.each do |recorder, thread|
      ran = thread.value
      expect(recorder.steps.map { _1["attempt_id"] }).to eq(ran.flat_map { attempt_ids(_1) })
    end
    expect(trials.map(&:trial_id).uniq.length).to eq(2)
  end

  it "drops an attempt of a trial with no recorder attached, and one made outside every trial" do
    other = Smith::Evals::Recorder.new(spec_for("t-9").trial_id)
    klass = asking("SpecStrayWorkflow")

    described_class.attach(other) do
      Smith::Evals.under(trial_context) { klass.new(context: {}).run! }
      klass.new(context: {}).run!
    end
    expect(other.steps).to eq([])
    expect(log.string).not_to include("observer error")
  end

  it "attaches one recorder a trial at a time, and detaches it when its block raises" do
    recorder = Smith::Evals::Recorder.new(trial_spec.trial_id)
    expect do
      described_class.attach(recorder) do
        expect { described_class.attach(Smith::Evals::Recorder.new(trial_spec.trial_id)) { nil } }
          .to raise_error(ArgumentError, "trial #{trial_spec.trial_id} already has a recorder attached")
        raise IOError, "the subject's host broke"
      end
    end.to raise_error(IOError)

    later = Smith::Evals::Recorder.new(trial_spec.trial_id)
    expect(described_class.attach(later) { :ran }).to eq(:ran)
    expect { described_class.attach(later) }.to raise_error(ArgumentError, "block required")
  end

  describe "Smith::Evals.under" do
    it "runs its block in the trial's scope, returning its value, and takes only a trial context" do
      inside = Smith::Evals.under(trial_context) { Smith::Attribution.current.trial }

      expect(inside).to eq(trial_spec.trial_id)
      expect(Smith::Attribution.current).to be_nil
      expect { Smith::Evals.under(trial_spec.trial_id) { nil } }.to raise_error(ArgumentError, /TrialContext/)
      expect { Smith::Evals.under(trial_context) }.to raise_error(ArgumentError, "block required")
    end

    # A host driver runs its subject inside its own attribution (its run's
    # key, say): the trial joins it, and its steps are placed by it.
    it "keeps the attribution a host gave around it, so a step's position holds the host's run key" do
      agent("SpecRecordingHostAgent")
      server.reply(json: message("Open at 8."))
      inside = nil
      recorder = Smith::Evals::Recorder.new(trial_spec.trial_id)
      described_class.attach(recorder) do
        Smith::Attribution.with(execution_key: "host-run-7", round: 2) do
          Smith::Evals.under(trial_context) do
            inside = Smith::Attribution.current.to_h.slice(:execution_key, :round, :trial)
            asking("SpecRecordingHostWorkflow").new(context: {}).run!
          end
        end
      end

      expect(inside).to eq(execution_key: "host-run-7", round: 2, trial: trial_spec.trial_id)
      expect(recorder.steps.sole["position"].slice("execution_key", "round"))
        .to eq("execution_key" => "host-run-7", "round" => 2)
    end
  end
end
