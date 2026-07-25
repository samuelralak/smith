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

  it "tracks complete-policy batch admission" do
    allowance = described_class.new(2, on_exhaustion: :complete)

    expect(allowance).to be_complete_on_exhaustion
    expect(allowance).not_to be_used
    reservation = allowance.reserve_batch(1)
    reservation.claim
    reservation.settle!
    allowance.charge!
    expect(allowance).to be_used
    expect(allowance.reserve_batch(1)).to be_nil
  end

  it "atomically consumes only a complete admitted batch" do
    allowance = described_class.new(4, on_exhaustion: :complete)
    results = Queue.new
    workers = Array.new(2) do
      Thread.new do
        reservation = allowance.reserve_batch(3)
        reservation&.settle!
        results << !reservation.nil?
      end
    end

    workers.each(&:join)

    expect(2.times.map { results.pop }.sort_by(&:to_s)).to eq([false, true])
    expect(allowance.remaining).to eq(1)
  end

  it "rejects an over-limit tool batch without consuming valid sibling capacity" do
    budget = Smith::Tool::CallBudget.new(
      total: 4,
      tool_limits: { "weather" => 1, "search" => 3 }
    )
    allowance = described_class.new(budget, on_exhaustion: :complete)

    expect(allowance.reserve_batch(%w[weather weather])).to be_nil
    expect(allowance.remaining).to eq(4)
    expect(allowance.remaining_for(:weather)).to eq(1)
    expect(allowance.remaining_for(:search)).to eq(3)

    reservation = allowance.reserve_batch(%w[weather search search])
    reservation.settle!
    expect(allowance.remaining).to eq(1)
    expect(allowance.remaining_for(:weather)).to eq(0)
    expect(allowance.remaining_for(:search)).to eq(1)
  end

  it "shares one exact root allowance across independently scoped branches" do
    root_budget = Smith::Tool::CallBudget.new(total: 1, tool_limits: { "weather" => 1 })
    branch_budget = Smith::Tool::CallBudget.new(total: 1, tool_limits: { "weather" => 1 })
    root = described_class.new(root_budget, on_exhaustion: :complete)
    admitted = Queue.new
    branches = Array.new(2) do
      branch = root.scope(branch_budget, on_exhaustion: :complete)
      Thread.new do
        reservation = branch.reserve_batch(["weather"])
        reservation&.settle!
        admitted << !reservation.nil?
      end
    end

    branches.each(&:join)

    expect(2.times.map { admitted.pop }.sort_by(&:to_s)).to eq([false, true])
    expect(root.remaining).to eq(0)
    expect(root.remaining_for(:weather)).to eq(0)
  end

  it "rejects tools absent from an exact allowance" do
    budget = Smith::Tool::CallBudget.new(total: 1, tool_limits: { "weather" => 1 })
    allowance = described_class.new(budget, on_exhaustion: :complete)

    expect(allowance.reserve_batch(["search"])).to be_nil
    expect(allowance.remaining).to eq(1)
  end

  it "validates exhaustion policy and batch size" do
    expect do
      described_class.new(1, on_exhaustion: :retry)
    end.to raise_error(ArgumentError, "tool call exhaustion policy must be :raise or :complete")

    allowance = described_class.new(1, on_exhaustion: :complete)
    [0, -1, 1.5].each do |size|
      expect { allowance.reserve_batch(size) }.to raise_error(
        ArgumentError,
        "tool call batch size must be a positive integer"
      )
    end
  end

  it "reserves the complete batch against the workflow ledger before admission" do
    allowance = described_class.new(2, on_exhaustion: :complete)
    ledger = Smith::Budget::Ledger.new(limits: { tool_calls: 1 })

    expect(allowance.reserve_batch(2, ledger:)).to be_nil
    expect(allowance.remaining).to eq(2)
    expect(ledger.consumed.fetch(:tool_calls, 0)).to eq(0)
  end

  it "reconciles unused workflow reservations after an admitted batch" do
    allowance = described_class.new(2, on_exhaustion: :complete)
    ledger = Smith::Budget::Ledger.new(limits: { tool_calls: 2 })
    reservation = allowance.reserve_batch(2, ledger:)

    reservation.claim
    reservation.settle!

    expect(allowance.remaining).to eq(0)
    expect(ledger.consumed.fetch(:tool_calls)).to eq(1)
    expect(ledger.remaining(:tool_calls)).to eq(1)
  end

  it "permits terminal settlement to retry after ledger reconciliation fails" do
    allowance = described_class.new(1, on_exhaustion: :complete)
    ledger = Smith::Budget::Ledger.new(limits: { tool_calls: 1 })
    reconciliation_attempts = 0
    allow(ledger).to receive(:reconcile!).and_wrap_original do |original, *arguments|
      reconciliation_attempts += 1
      raise "ledger temporarily unavailable" if reconciliation_attempts == 1

      original.call(*arguments)
    end
    reservation = allowance.reserve_batch(1, ledger:)
    reservation.claim

    expect { reservation.settle! }.to raise_error(RuntimeError, "ledger temporarily unavailable")
    expect { reservation.settle! }.not_to raise_error
    expect(reconciliation_attempts).to eq(2)
    expect(ledger.consumed.fetch(:tool_calls)).to eq(1)
  end

  it "preserves the legacy remaining reader" do
    allowance = described_class.new(2)

    expect(allowance[:remaining]).to eq(2)
    expect(allowance[:unknown]).to be_nil
  end

  it "fails closed when a scoped budget would nest under a legacy Hash allowance" do
    Smith::Tool.current_tool_call_allowance = { remaining: 3 }

    expect do
      Smith::Tool.with_call_budget(2) { raise "unreachable" }
    end.to raise_error(
      ArgumentError,
      "a scoped tool call budget cannot nest under a legacy Hash tool call allowance"
    )
    expect(Smith::Tool.current_tool_call_allowance).to eq(remaining: 3)
  ensure
    Smith::Tool.current_tool_call_allowance = nil
  end

  it "fails closed when an agent tool_calls budget would scope a legacy Hash allowance" do
    agent_class = Class.new do
      def self.budget = { tool_calls: 2 }

      def self.tool_budget_exhaustion = :raise
    end
    enforcement = Class.new do
      include Smith::Workflow::DeadlineEnforcement

      def enter_agent_context(agent_class, &block) = with_agent_context(agent_class, &block)
    end.new
    Smith::Tool.current_tool_call_allowance = { remaining: 3 }

    expect do
      enforcement.enter_agent_context(agent_class) { raise "unreachable" }
    end.to raise_error(
      Smith::AgentError,
      "agent tool_calls budgets cannot scope a legacy Hash tool call allowance"
    )
    expect(Smith::Tool.current_tool_call_allowance).to eq(remaining: 3)
  ensure
    Smith::Tool.current_tool_call_allowance = nil
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

  it "restores the caller context when a budget scope is interrupted" do
    entered = Queue.new
    release = Queue.new
    thread = Thread.new do
      Smith::Tool.with_call_budget(1) do
        entered << true
        release.pop
      end
    rescue Interrupt => e
      [e, Smith::Tool.current_tool_call_allowance]
    end
    thread.report_on_exception = false
    entered.pop

    thread.raise(Interrupt, "cancelled")
    release << true
    error, restored = thread.value

    expect(error).to be_a(Interrupt)
    expect(error.message).to eq("cancelled")
    expect(restored).to be_nil
  ensure
    release << true if thread&.alive?
    thread&.join
  end
end
