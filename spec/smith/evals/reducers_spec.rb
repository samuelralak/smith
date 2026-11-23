# frozen_string_literal: true

require "smith/evals"

# The named reducers (slice-1a design 4.4): a sample's value from its
# counted trials, and the names records give them.
RSpec.describe Smith::Evals::Reducers do
  it "names each reducer as records do" do
    expect(%i[majority any all mean].map { described_class.name_of(_1) }).to eq(%w[majority any all mean])
    expect(described_class.name_of(pass_at: 2)).to eq("pass_at_2")
    expect(described_class.name_of({ pass_all: 3 })).to eq("pass_all_3")
    expect(described_class.name_of("pass_at_12")).to eq("pass_at_12")
    expect(described_class.k("pass_all_3")).to eq(3)
    expect(described_class.k("mean")).to be_nil
  end

  it "refuses a name it does not know" do
    bad_names = [:median, "pass_at_0", { pass_at: 0 }, { pass_at: 100 }, { pass_at: 2, pass_all: 2 }, "pass_at_x", nil]
    bad_names.each do |bad|
      expect { described_class.name_of(bad) }.to raise_error(ArgumentError, /majority, any, all, mean/), bad.inspect
    end
  end

  it "fits mean to both scales and the rest to binary only" do
    expect(%w[majority any all mean pass_at_2 pass_all_2].map { described_class.fits?(_1, :binary) }.uniq).to eq([true])
    expect(%w[majority any all pass_at_2 pass_all_2].map { described_class.fits?(_1, :continuous) }.uniq).to eq([false])
    expect(described_class.fits?("mean", :continuous)).to be(true)
  end

  it "reduces counted trials as the table says, a tie failing the majority" do
    trials = [true, false, true]

    expect(%w[majority any all mean].map { described_class.value(_1, trials) }).to eq([1.0, 1.0, 0.0, 2.0 / 3])
    expect(described_class.value("majority", [true, false])).to eq(0.0)
    expect(described_class.value("all", [true, true])).to eq(1.0)
    expect(described_class.value("any", [false, false])).to eq(0.0)
    expect(described_class.value("mean", [0.25, 0.5])).to eq(0.375)
  end

  it "reduces pass@k and pass^k by the unbiased estimators" do
    expect(described_class.value("pass_at_2", [true, false, false])).to eq(2.0 / 3) # 1 - C(2, 2)/C(3, 2), exactly
    expect(described_class.value("pass_all_2", [true, true, false])).to eq(1.0 / 3)
    expect(described_class.value("pass_at_1", [true, false, false, false])).to eq(0.25)
  end

  it "agrees with the statistics module's estimate on one sample, for every reducer" do
    statistics = Smith::Evals::Statistics
    [[true, false, true, true], [false, false, true], [true, true, true]].each do |trials|
      %w[majority any all mean pass_at_2 pass_all_2].each do |name|
        sample = statistics::Sample.new(id: "s", trials:)
        expected = statistics.estimate(samples: [sample], reducer: name).point

        expect(described_class.value(name, trials)).to be_within(1e-15).of(expected), "#{name} #{trials}"
      end
    end
  end

  it "refuses trials it cannot reduce" do
    expect { described_class.value("mean", []) }.to raise_error(ArgumentError, /at least one/)
    expect { described_class.value("pass_at_3", [true, false]) }.to raise_error(ArgumentError, /at least 3/)
    expect { described_class.value("majority", [0.5]) }.to raise_error(ArgumentError, /true or false/)
    expect { described_class.value("mean", [true, 0.5]) }.to raise_error(ArgumentError, /all true or false, or all/)
  end
end
