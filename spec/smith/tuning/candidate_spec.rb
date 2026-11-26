# frozen_string_literal: true

require "smith/tuning"

# A candidate (slice 5a design, sections 2 and 3): a text for each tuned
# component, the seed's from the subject's named prompts; a child changes
# one component through Prompt#with_text, so a text that changes the
# component's fill-in fields is refused; its id is the run's, the
# iteration's and every component's version.
RSpec.describe Smith::Tuning::Candidate do
  let(:run) { "tu_#{"1" * 32}" }
  let(:prompts) do
    { "summarize1.predict" => Smith::Prompt.new("summarize1.predict", "Summarize the passages."),
      "final_answer.predict" => Smith::Prompt.new("final_answer.predict", "Answer {{question}}."),
      "other.predict" => Smith::Prompt.new("other.predict", "Not tuned.") }
  end
  let(:seed) do
    described_class.seed(prompts, components: %w[final_answer.predict summarize1.predict], tuning_run_id: run)
  end

  def version(text) = "sha256:#{Digest::SHA256.hexdigest(text)}"

  it "seeds from the subject's named prompts, the tuned ones in the order given" do
    versions = { "final_answer.predict" => version("Answer {{question}}."),
                 "summarize1.predict" => version("Summarize the passages.") }

    expect(seed.texts).to eq("final_answer.predict" => "Answer {{question}}.",
                             "summarize1.predict" => "Summarize the passages.")
    expect(seed.versions).to eq(versions)
    expect(seed.versions.keys).to eq(%w[final_answer.predict summarize1.predict])
    expect([seed.iteration, seed.parent, seed.component, seed.idea]).to eq([0, nil, nil, nil])
    expect(seed.candidate_id)
      .to eq(Smith::Evals::Identity.candidate_id(tuning_run_id: run, iteration: 0, versions:))
    expect(described_class.seed(prompts, components: nil, tuning_run_id: run).versions.keys).to eq(prompts.keys)
    expect(seed).to be_frozen
  end

  it "makes a child that changes one component, keeping the others' texts" do
    child = seed.child("final_answer.predict", "Answer {{question}} in a few words.", iteration: 4, parent: 0,
                                                                                      idea: "Be brief.")

    expect(child.texts).to eq("final_answer.predict" => "Answer {{question}} in a few words.",
                              "summarize1.predict" => "Summarize the passages.")
    expect([child.iteration, child.parent, child.component,
            child.idea]).to eq([4, 0, "final_answer.predict", "Be brief."])
    expect(child.versions["final_answer.predict"]).to eq(version("Answer {{question}} in a few words."))
    expect(child.candidate_id)
      .to eq(Smith::Evals::Identity.candidate_id(tuning_run_id: run, iteration: 4, versions: child.versions))
    expect(seed.texts["final_answer.predict"]).to eq("Answer {{question}}.")
  end

  it "refuses a text that changes the component's fill-in fields, and a component it does not tune" do
    expect { seed.child("final_answer.predict", "Answer.", iteration: 1, parent: 0) }
      .to raise_error(Smith::PromptInvalid, /fill-in fields/)
    expect { seed.child("final_answer.predict", "Answer {{question}} for {{person}}.", iteration: 1, parent: 0) }
      .to raise_error(Smith::PromptInvalid, /fill-in fields/)
    expect { seed.child("other.predict", "x", iteration: 1, parent: 0) }
      .to raise_error(ArgumentError, /other.predict is not a tuned component/)
    expect { seed.child("final_answer.predict", "Answer {{question}}!", iteration: 0, parent: 0) }
      .to raise_error(ArgumentError, /iteration/)
  end

  it "refuses tuned components the subject does not send" do
    expect { described_class.seed(prompts, components: %w[missing.predict], tuning_run_id: run) }
      .to raise_error(ArgumentError, /missing.predict, which the subject does not send/)
    expect { described_class.seed({}, components: nil, tuning_run_id: run) }
      .to raise_error(ArgumentError, /no named prompt/)
  end

  # The eval header's candidate (design section 3): its id, its run, and
  # each component's version, the texts living in the tuning record.
  it "names itself for an eval run's header, valid against the common schema" do
    reference = seed.reference

    expect(reference).to eq("candidate_id" => seed.candidate_id, "tuning_run_id" => run,
                            "components" => [{ "id" => "final_answer.predict",
                                               "version" => version("Answer {{question}}.") },
                                             { "id" => "summarize1.predict",
                                               "version" => version("Summarize the passages.") }])
    %i[open strict].each do |mode|
      expect(EvalsSchema.errors(reference, schema: "common", pointer: "#/$defs/candidate", strict: mode == :strict))
        .to eq([])
    end
  end
end
