# frozen_string_literal: true

RSpec.describe Smith::Trace::Memory do
  it "defaults to a generous bound and counts entries dropped beyond it" do
    adapter = described_class.new(limit: 2)

    3.times { |index| adapter.record(type: :transition, data: { state: :"s#{index}" }) }

    expect(adapter.traces.length).to eq(2)
    expect(adapter.dropped_count).to eq(1)
    expect(adapter.traces.map { |t| t[:data] }).to eq([{ state: :s0 }, { state: :s1 }])
  end

  it "rejects a non-positive or non-integer limit" do
    expect { described_class.new(limit: 0) }.to raise_error(ArgumentError, /positive integer/)
    expect { described_class.new(limit: "10") }.to raise_error(ArgumentError, /positive integer/)
  end

  it "clear! resets both the traces and the dropped counter" do
    adapter = described_class.new(limit: 1)
    2.times { adapter.record(type: :transition, data: { state: :busy }) }

    adapter.clear!

    expect(adapter.traces).to eq([])
    expect(adapter.dropped_count).to eq(0)
  end

  it "snapshot returns a consistent copy that does not grow with later records" do
    adapter = described_class.new
    adapter.record(type: :transition, data: { state: :one })

    snapshot = adapter.snapshot
    adapter.record(type: :transition, data: { state: :two })

    expect(snapshot.length).to eq(1)
    expect(adapter.traces.length).to eq(2)
  end

  it "records safely under concurrent writers" do
    adapter = described_class.new(limit: 1_000)
    start = Queue.new
    threads = 8.times.map do
      Thread.new do
        start.pop
        50.times { adapter.record(type: :transition, data: { state: :parallel }) }
      end
    end

    8.times { start << :go }
    threads.each { |thread| thread.join(5) || raise("writer thread did not finish") }

    expect(adapter.traces.length).to eq(400)
    expect(adapter.dropped_count).to eq(0)
  end
end
