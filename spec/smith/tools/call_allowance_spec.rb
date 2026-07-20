# frozen_string_literal: true

RSpec.describe Smith::Tool::CallAllowance do
  it "admits exactly the configured number of concurrent calls" do
    allowance = described_class.new(4)
    admitted = Queue.new
    denied = Queue.new
    workers = Array.new(20) do
      Thread.new do
        allowance.charge! { admitted << true }
      rescue Smith::BudgetExceeded
        denied << true
      end
    end

    workers.each(&:join)

    expect(admitted.size).to eq(4)
    expect(denied.size).to eq(16)
    expect(allowance.remaining).to eq(0)
  end

  it "does not consume allowance when the enclosed workflow charge fails" do
    allowance = described_class.new(1)

    expect { allowance.charge! { raise "ledger rejected" } }.to raise_error(RuntimeError, "ledger rejected")
    expect(allowance.remaining).to eq(1)
  end

  it "validates its bound before publication" do
    [nil, -1, 1.5].each do |invalid|
      expect { described_class.new(invalid) }.to raise_error(
        ArgumentError,
        "tool call allowance must be a non-negative integer"
      )
    end
  end

  it "supports a zero-call deny-all allowance" do
    allowance = described_class.new(0)

    expect(allowance.remaining).to eq(0)
    expect { allowance.charge! }.to raise_error(Smith::BudgetExceeded)
  end

  it "preserves the legacy remaining reader" do
    allowance = described_class.new(2)

    expect(allowance[:remaining]).to eq(2)
    expect(allowance[:unknown]).to be_nil
  end

  it "preserves synchronized legacy hash allowance semantics" do
    allowance = { remaining: 4 }
    admitted = Queue.new
    denied = Queue.new
    workers = Array.new(20) do
      Thread.new do
        described_class.charge_legacy!(allowance) { admitted << true }
      rescue Smith::BudgetExceeded
        denied << true
      end
    end

    workers.each(&:join)

    expect(admitted.size).to eq(4)
    expect(denied.size).to eq(16)
    expect(allowance).to eq(remaining: 0)
  end

  it "does not admit a waiter cancelled before it acquires the allowance lock" do
    allowance = described_class.new(2)
    first_started = Queue.new
    release_first = Queue.new
    admitted = Queue.new
    waiter_started = Queue.new
    first = Thread.new do
      allowance.charge! do
        first_started << true
        release_first.pop
        admitted << :first
      end
    end
    first_started.pop
    waiter = Thread.new do
      waiter_started << true
      allowance.charge! { admitted << :waiter }
      nil
    rescue Exception => e # rubocop:disable Lint/RescueException
      e
    end
    waiter_started.pop
    waiter.raise(Interrupt, "cancelled")

    expect(waiter.value).to be_a(Interrupt)
    expect(waiter.value.message).to eq("cancelled")
    release_first << true
    first.join
    expect(admitted.pop).to eq(:first)
    expect(admitted).to be_empty
    expect(allowance.remaining).to eq(1)
  ensure
    release_first << true if first&.alive?
    first&.join
    waiter&.join
  end

  it "does not serialize unrelated legacy allowances" do
    first_allowance = { remaining: 1 }
    second_allowance = { remaining: 1 }
    first_started = Queue.new
    release_first = Queue.new
    first = Thread.new do
      described_class.charge_legacy!(first_allowance) do
        first_started << true
        release_first.pop
      end
    end
    first_started.pop
    second = Thread.new { described_class.charge_legacy!(second_allowance) }

    expect(second.join(1)).to equal(second)
    expect(second_allowance).to eq(remaining: 0)
  ensure
    release_first << true if first&.alive?
    first&.join
    second&.join
  end
end
