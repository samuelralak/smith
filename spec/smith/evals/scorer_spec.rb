# frozen_string_literal: true

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
end
