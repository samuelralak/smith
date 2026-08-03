# frozen_string_literal: true

RSpec.describe Smith::Attribution do
  after do
    Thread.current[described_class::THREAD_KEY] = nil
  end

  it "has no ambient context by default" do
    expect(described_class.current).to be_nil
    expect(described_class.current_fields).to eq({})
  end

  it "overlays fields for the block and restores the previous context" do
    described_class.with(execution_key: "run-1") do
      expect(described_class.current_fields).to eq(execution_key: "run-1")

      described_class.with(transition: :fetch, round: 0) do
        expect(described_class.current_fields).to eq(
          execution_key: "run-1", transition: :fetch, round: 0
        )
      end

      expect(described_class.current_fields).to eq(execution_key: "run-1")
    end

    expect(described_class.current).to be_nil
  end

  it "restores the previous context when the block raises" do
    expect do
      described_class.with(execution_key: "run-2") { raise ArgumentError, "boom" }
    end.to raise_error(ArgumentError, "boom")

    expect(described_class.current).to be_nil
  end

  it "override replaces fields verbatim, nil included" do
    context = described_class::EMPTY.merge(execution_key: "run-9", transition: :outer, from: :somewhere)

    replaced = context.override(transition: :inner, from: nil, to: nil)

    expect(replaced.transition).to eq(:inner)
    expect(replaced.from).to be_nil
    expect(replaced.to).to be_nil
    # Fields not named keep their values.
    expect(replaced.execution_key).to eq("run-9")
  end

  it "ignores nil overrides so an inner scope cannot blank an outer value" do
    described_class.with(execution_key: "run-3", transition: :plan) do
      described_class.with(execution_key: nil, branch_key: :left) do
        expect(described_class.current_fields).to eq(
          execution_key: "run-3", transition: :plan, branch_key: :left
        )
      end
    end
  end

  it "requires a block for with and carrying" do
    expect { described_class.with(execution_key: "x") }.to raise_error(ArgumentError, "block required")
    expect { described_class.carrying(nil) }.to raise_error(ArgumentError, "block required")
  end

  it "carrying installs a captured context and clears a stale one when given nil" do
    captured = described_class::EMPTY.merge(execution_key: "parent", transition: :spread)

    described_class.carrying(captured) do
      expect(described_class.current_fields).to eq(execution_key: "parent", transition: :spread)
    end

    described_class.with(execution_key: "stale") do
      described_class.carrying(nil) do
        expect(described_class.current).to be_nil
      end

      expect(described_class.current_fields).to eq(execution_key: "stale")
    end
  end

  it "is thread-isolated" do
    handoff = Queue.new
    observed = nil

    described_class.with(execution_key: "main-thread") do
      thread = Thread.new do
        observed = described_class.current
        handoff << :done
      end
      handoff.pop
      thread.join
    end

    expect(observed).to be_nil
  end

  it "contexts are frozen values" do
    context = described_class::EMPTY.merge(execution_key: "run-4")

    expect(context).to be_frozen
    expect(described_class::EMPTY.merge).to equal(described_class::EMPTY)
  end
end
