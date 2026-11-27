# frozen_string_literal: true

require "tmpdir"
require "smith/evals"

# Code scorers (slice-1a design 4.3): a class reusable across suites, or a
# block in a suite. Each runs outside trial isolation, on what the trial
# line keeps, and whatever it does gives a Score.
RSpec.describe Smith::Evals::Scorer do
  let(:trial) { Struct.new(:state, :output, :failure).new({ triage: { category: "billing" } }, nil, nil) }
  let(:sample) { Struct.new(:expected).new({ category: "billing" }) }

  let(:category_scorer) do
    Class.new(described_class) do
      scorer_name :category
      version 2
      scale :binary

      def score(sample, trial)
        Smith::Evals::Score.match(trial.state.dig(:triage, :category), sample.expected[:category])
      end
    end
  end

  it "reads a class scorer's name, version, scale and failure rule, with defaults" do
    scorer = category_scorer.new

    expect([scorer.name, scorer.version, scorer.scale, scorer.on_subject_failure])
      .to eq(["category", 2, :binary, :fail])
    expect(scorer.evaluate(sample, trial)).to have_attributes(passed: true, explanation: "matched billing")
  end

  it "inherits a class scorer's settings, and lets a subclass change one" do
    refusal = Class.new(category_scorer) { on_subject_failure :score }

    expect([refusal.new.name, refusal.new.version, refusal.new.on_subject_failure]).to eq(["category", 2, :score])
    expect(category_scorer.new.on_subject_failure).to eq(:fail)
  end

  it "wraps a block as a scorer" do
    block = described_class::Block.new(name: :quality, version: 1, scale: :continuous) { |_sample, _trial| Smith::Evals::Score.value(0.5) }

    expect([block.name, block.version, block.scale, block.on_subject_failure]).to eq(["quality", 1, :continuous, :fail])
    expect(block.evaluate(sample, trial).value).to eq(0.5)
  end

  it "turns a score on the other scale, or no score at all, into unscored score_invalid" do
    continuous = described_class::Block.new(name: :q, version: 1, scale: :binary) { |*| Smith::Evals::Score.value(0.5) }
    nothing = described_class::Block.new(name: :q, version: 1, scale: :binary) { |*| true }
    binary = described_class::Block.new(name: :q, version: 1, scale: :continuous) { |*| Smith::Evals::Score.pass }

    [continuous, nothing, binary].each do |scorer|
      expect(scorer.evaluate(sample, trial))
        .to have_attributes(status: :unscored, reason: include("code" => "score_invalid"))
    end
  end

  it "turns a scorer that raises into unscored scorer_raised, naming the error's class only" do
    raising = described_class::Block.new(name: :q, version: 1, scale: :binary) { |*| raise KeyError, "secret text" }
    score = raising.evaluate(sample, trial)

    expect(score).to have_attributes(status: :unscored, reason: { "code" => "scorer_raised", "by" => "grader",
                                                                  "detail" => "scorer q raised KeyError" })
    expect(score.explanation).not_to include("secret")
  end

  it "keeps an unscored score its scorer returned as it is" do
    undecided = described_class::Block.new(name: :q, version: 1, scale: :binary) { |*| Smith::Evals::Score.unscored("no priority") }

    expect(undecided.evaluate(sample, trial).reason["code"]).to eq("grader_undecided")
  end

  # Slice 5a: the tuner asks a scorer for feedback text on one component of
  # one training trial; whether that text may name the expected answer is
  # the scorer's opt-in (the owner's ruling on Q4).
  describe "feedback for the tuner" do
    it "gives none by default, keeps the expected answer out by default, and says whether it gives any" do
      scorer = category_scorer.new

      expect(scorer.feedback(sample, trial, component: "triage.rules")).to be_nil
      expect([scorer.reveals_expected, scorer.feedback?]).to eq([false, false])
    end

    it "takes a class scorer's feedback and its opt-in to naming the expected answer, which a subclass inherits" do
      explained = Class.new(category_scorer) do
        reveals_expected true

        def feedback(sample, _trial, component:) = "#{component}: the answer is #{sample.expected[:category]}"
      end

      expect(explained.new.feedback(sample, trial, component: "triage.rules"))
        .to eq("triage.rules: the answer is billing")
      expect([explained.new.reveals_expected, explained.new.feedback?]).to eq([true, true])
      expect(Class.new(explained).new.reveals_expected).to be(true)
    end

    it "takes a block scorer's feedback as a callable, and its opt-in" do
      told = described_class::Block.new(name: :category, version: 1, reveals_expected: true,
                                        feedback: ->(_sample, _trial, component:) { "#{component} was vague" }) do
        Smith::Evals::Score.pass
      end
      plain = described_class::Block.new(name: :category, version: 1) { Smith::Evals::Score.pass }

      expect(told.feedback(sample, trial, component: "a.b")).to eq("a.b was vague")
      expect([told.reveals_expected, told.feedback?, plain.reveals_expected, plain.feedback?])
        .to eq([true, true, false, false])
      expect(plain.feedback(sample, trial, component: "a.b")).to be_nil
    end

    it "is given a suite's block scorer's feedback and opt-in, which stay out of its manifest" do
      dir = Dir.mktmpdir
      TuningRecords.dataset(dir)
      flow = with_stubbed_class("SpecFeedbackFlow", Smith::Workflow)
      plain = Class.new(Smith::Evals::Suite) do
        suite_name "spec.feedback"
        dataset dir
        subject workflow: flow, input: ->(_sample) { {} }
        scorer(:exact, version: 1) { Smith::Evals::Score.pass }
      end
      told = Class.new(plain) { settings[:scorers].clear }
      told.scorer(:exact, version: 1, reveals_expected: true, feedback: ->(*, component:) { component }) do
        Smith::Evals::Score.pass
      end
      scorer = told.scorers.sole.scorer

      expect([scorer.feedback(sample, trial, component: "x.y"), scorer.reveals_expected]).to eq(["x.y", true])
      expect(told.manifest["scorers"]).to eq(plain.manifest["scorers"])
    ensure
      FileUtils.rm_rf(dir)
    end
  end
end
