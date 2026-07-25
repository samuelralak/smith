# frozen_string_literal: true

RSpec.describe Smith::Tool::CallBudget do
  it "owns an immutable aggregate and per-tool allowance vector" do
    budget = described_class.new(total: 4, tool_limits: { "weather" => 1, "search" => 3 })

    expect(budget.total).to eq(4)
    expect(budget.limit_for(:weather)).to eq(1)
    expect(budget.limit_for("search")).to eq(3)
    expect(budget).to be_exact
    expect(budget).to be_frozen
    expect(budget.tool_limits).to be_frozen
  end

  it "supports an aggregate-only compatibility budget" do
    budget = described_class.coerce(2)

    expect(budget.total).to eq(2)
    expect(budget).not_to be_exact
    expect(budget.tool_limits).to be_nil
  end

  it "rejects an aggregate that cannot be satisfied by its exact limits" do
    expect do
      described_class.new(total: 3, tool_limits: { "weather" => 1, "search" => 1 })
    end.to raise_error(ArgumentError, "aggregate tool call allowance exceeds the sum of its per-tool limits")
  end
end
