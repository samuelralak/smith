# frozen_string_literal: true

RSpec.describe "Smith budget ledger contract" do
  let(:ledger_class) { require_const("Smith::Budget::Ledger") }

  def build_ledger(limit:)
    ledger_class.new(limits: { tokens: limit })
  end

  it "reserves capacity against committed plus reserved usage" do
    ledger = build_ledger(limit: 100)

    expect { ledger.reserve!(:tokens, 40) }.not_to raise_error
    expect { ledger.reserve!(:tokens, 50) }.not_to raise_error
    expect { ledger.reserve!(:tokens, 11) }.to raise_error(require_const("Smith::BudgetExceeded"))
  end

  it "reconciles by releasing the reservation and charging actual usage" do
    ledger = build_ledger(limit: 100)

    ledger.reserve!(:tokens, 40)
    ledger.reconcile!(:tokens, 40, 25)

    expect { ledger.reserve!(:tokens, 75) }.not_to raise_error
    expect { ledger.reserve!(:tokens, 1) }.to raise_error(require_const("Smith::BudgetExceeded"))
  end

  it "releases reservations on failure without leaking capacity" do
    ledger = build_ledger(limit: 100)

    ledger.reserve!(:tokens, 40)
    ledger.release!(:tokens, 40)

    expect { ledger.reserve!(:tokens, 100) }.not_to raise_error
    expect { ledger.reserve!(:tokens, 1) }.to raise_error(require_const("Smith::BudgetExceeded"))
  end
end
