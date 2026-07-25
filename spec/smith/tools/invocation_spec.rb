# frozen_string_literal: true

RSpec.describe Smith::Tool::Invocation do
  it "is immutable and validates its batch position" do
    tool_call_id = +"call-1"
    tool_name = +"web_search"
    invocation = described_class.new(
      tool_call_id:,
      tool_name:,
      ordinal: 3,
      batch_ordinal: 1,
      batch_size: 2
    )

    expect(invocation).to be_frozen
    expect(invocation.to_h).to eq(
      tool_call_id: "call-1",
      tool_name: "web_search",
      ordinal: 3,
      batch_ordinal: 1,
      batch_size: 2
    )
    tool_call_id << "-changed"
    tool_name << "-changed"

    expect(invocation.tool_call_id).to eq("call-1")
    expect(invocation.tool_name).to eq("web_search")
    expect(invocation.tool_call_id).to be_frozen
    expect(invocation.tool_name).to be_frozen
  end

  it "rejects a batch ordinal beyond the batch size" do
    expect do
      described_class.new(
        tool_call_id: "call-1",
        tool_name: "web_search",
        ordinal: 1,
        batch_ordinal: 2,
        batch_size: 1
      )
    end.to raise_error(ArgumentError, "tool invocation batch ordinal exceeds its batch size")
  end
end

RSpec.describe Smith::Tool::InvocationSequence do
  it "reserves non-overlapping contiguous ordinal ranges concurrently" do
    sequence = described_class.new
    starts = Queue.new
    threads = 20.times.map do
      Thread.new { starts << sequence.reserve(3) }
    end
    threads.each(&:join)

    ranges = 20.times.map { starts.pop }.sort.map { _1...(_1 + 3) }

    expect(ranges.flat_map(&:to_a)).to eq((1..60).to_a)
  end

  it "rejects invalid reservation sizes without advancing" do
    sequence = described_class.new

    expect { sequence.reserve(0) }.to raise_error(ArgumentError, "tool invocation batch size must be positive")
    expect(sequence.reserve(1)).to eq(1)
  end

  it "starts from an explicit host resume ordinal" do
    sequence = described_class.new(next_ordinal: 7)

    expect(sequence.reserve(2)).to eq(7)
    expect(sequence.reserve(1)).to eq(9)
  end

  it "rejects an invalid starting ordinal" do
    expect { described_class.new(next_ordinal: 0) }
      .to raise_error(ArgumentError, "next tool invocation ordinal must be positive")
  end
end
