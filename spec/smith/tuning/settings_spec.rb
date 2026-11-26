# frozen_string_literal: true

require "smith/tuning"

# A tuning run's settings (slice 5a design, sections 1 and 3): checked when
# built, defaults as the design gives them, and the header's settings block.
RSpec.describe Smith::Tuning::Settings do
  let(:split) { { train: { tags_any: ["train"] }, validation: { tags_any: ["val"] } } }
  let(:reflection) do
    { model: "gpt-4.1-mini-2025-04-14", provider: :openai, temperature: 1.0, max_output_tokens: 16_384 }
  end

  def settings(**options) = described_class.new(objective: :exact_match, split:, reflection:, **options)

  it "takes the design's defaults and writes the header's settings block" do
    built = settings(stop: { max_metric_calls: 1_100, rounds_without_improvement: nil })

    expect([built.objective, built.components, built.minibatch, built.seed]).to eq(["exact_match", nil, 3, 0])
    expect(built.split).to eq(train: { tags_any: ["train"] }, validation: { tags_any: ["val"] }, override: nil)
    expect(built.to_h).to eq(
      "minibatch" => 3, "seed" => 0, "skip_perfect" => true, "perfect_score" => 1.0, "failure_score" => 0,
      "selection" => "pareto/1", "rotation" => "round_robin/1", "accept" => "strict_mean/1", "merge" => false,
      "stop" => { "max_metric_calls" => 1_100, "max_cost_nanos" => nil, "max_candidates" => 1_000,
                  "rounds_without_improvement" => nil, "deadline" => nil },
      "reflection" => { "model" => "gpt-4.1-mini-2025-04-14", "provider" => "openai",
                        "settings" => { "temperature" => 1.0, "max_output_tokens" => 16_384, "thinking" => nil },
                        "prompt" => { "id" => "smith.tuning.reflect",
                                      "version" => Smith::Tuning::Reflection::PROMPT.version } }
    )
    expect(built).to be_frozen
  end

  # Question 1, as ruled: the plan's five rounds without improvement is the
  # default; the pilot turns it off.
  it "stops after five rounds without improvement unless told otherwise" do
    expect(settings.stop).to eq(max_metric_calls: nil, max_cost_nanos: nil, max_candidates: 1_000,
                                rounds_without_improvement: 5, deadline: nil)
  end

  it "keeps the components in the order given, the deadline as a UTC time, and a host's ledger out of the record" do
    ledger = Object.new
    given = reflection.merge(budget_ledger: ledger, thinking: { effort: :low })
    built = settings(components: %w[b.predict a.predict], minibatch: 4, seed: 2, skip_perfect: false,
                     perfect_score: 0.9, reflection: given,
                     stop: { max_cost_nanos: 5_000_000_000, deadline: Time.new(2026, 11, 30, 12, 0, 0, "+03:00") })

    expect(built.components).to eq(%w[b.predict a.predict])
    expect(built.reflection.budget_ledger).to equal(ledger)
    expect(built.to_h.values_at("minibatch", "seed", "skip_perfect", "perfect_score")).to eq([4, 2, false, 0.9])
    expect(built.to_h.dig("stop", "deadline")).to eq("2026-11-30T09:00:00.000Z")
    expect(built.to_h.dig("reflection", "settings", "thinking")).to eq("effort" => "low")
    expect(built.to_h.to_s).not_to include("budget_ledger")
  end

  it "records a split override with who asked and why" do
    actor = Smith::Evals::Actor.person("usr_51a8")
    built = settings(split: split.merge(override: { actor:, reason: "a small first set" }))

    expect(built.split[:override]).to eq(actor:, reason: "a small first set")
    expect(settings(split: split.merge(override: { actor: actor.to_h, reason: "r" })).split.dig(:override, :actor))
      .to eq(actor)
  end

  it "takes ids as a narrowing too" do
    expect(settings(split: { train: { ids: %w[a b] }, validation: { ids: ["c"] } }).split[:train]).to eq(ids: %w[a b])
  end

  # The carve of dev (5a-F) is not built: a run names its split.
  it "needs a split until the carve of dev is built" do
    expect { described_class.new(objective: :exact_match, split: nil, reflection:) }
      .to raise_error(ArgumentError, /split.*carve/)
  end

  it "refuses every setting it cannot run" do
    bad = {
      objective: [{ objective: "Exact Match" }, { objective: nil }],
      components: [{ components: [] }, { components: %w[a.b a.b] }, { components: ["Bad Id"] }, { components: "a" }],
      split: [{ split: { train: { tags_any: ["t"] } } }, { split: split.merge(extra: 1) },
              { split: split.merge(train: { tags_any: [] }) }, { split: split.merge(train: { ids: %w[a a] }) },
              { split: split.merge(train: { ids: ["a"], tags_any: ["t"] }) },
              { split: split.merge(train: { tag: ["t"] }) },
              { split: split.merge(override: { actor: nil, reason: "r" }) },
              { split: split.merge(override: { actor: Smith::Evals::Actor.person("u"), reason: "" }) }],
      minibatch: [{ minibatch: 0 }, { minibatch: 1.5 }],
      seed: [{ seed: -1 }, { seed: 2**53 }, { seed: "0" }],
      skip_perfect: [{ skip_perfect: nil }],
      perfect_score: [{ perfect_score: 1.5 }, { perfect_score: -0.1 }, { perfect_score: "1" }],
      reflection: [{ reflection: reflection.except(:model) }, { reflection: reflection.merge(provider: nil) },
                   { reflection: reflection.merge(temperature: "hot") },
                   { reflection: reflection.merge(max_output_tokens: 0) },
                   { reflection: reflection.merge(thinking: "low") }, { reflection: reflection.merge(seed: 1) },
                   { reflection: reflection.merge(thinking: {}) },
                   { reflection: reflection.merge(thinking: { level: 1 }) },
                   { reflection: reflection.merge(thinking: { budget: 0 }) }],
      stop: [{ stop: { max_metric_calls: 0 } }, { stop: { max_cost_nanos: -1 } }, { stop: { max_candidates: 0 } },
             { stop: { deadline: "tomorrow" } }, { stop: { rounds_without_improvement: 0 } }, { stop: { other: 1 } },
             { stop: { rounds_without_improvement: nil } }]
    }

    bad.each do |name, cases|
      cases.each do |options|
        expect { settings(**options) }.to raise_error(ArgumentError, /#{name}/), options.inspect
      end
    end
  end
end
