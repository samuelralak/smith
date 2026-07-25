# frozen_string_literal: true

RSpec.describe Smith::Tool::CallAdmission do
  let(:tool) { Object.new }
  let(:reservation) do
    Smith::Tool::CallReservation.new(limit: 1, ledger: nil, ledger_reservation: nil)
  end

  it "can be claimed exactly once" do
    admission = described_class.new(tool:, reservation:)

    expect(admission.claim(tool)).to be(true)
    expect(admission.claim(tool)).to be(false)
  end

  it "fails closed when the reservation refuses the claim" do
    reservation = double(:reservation, claim: false)
    tool = Object.new
    admission = described_class.new(tool:, reservation:)

    expect(admission.claim(tool)).to be(false)
    expect(admission.claim(tool)).to be(false)
  end

  it "fails closed when the batch reservation is already settled" do
    reservation.settle!
    admission = described_class.new(tool:, reservation:)

    expect(admission.claim(tool)).to be(false)
  end

  it "fails closed when the shared batch reservation is exhausted" do
    sibling_tool = Object.new
    sibling = described_class.new(tool: sibling_tool, reservation:)
    admission = described_class.new(tool:, reservation:)

    expect(sibling.claim(sibling_tool)).to be(true)
    expect(admission.claim(tool)).to be(false)
  end

  it "restores the enclosing admission after a nested scope" do
    outer = described_class.new(tool:, reservation:)
    inner_tool = Object.new
    inner_reservation = Smith::Tool::CallReservation.new(limit: 1, ledger: nil, ledger_reservation: nil)
    inner = described_class.new(tool: inner_tool, reservation: inner_reservation)

    described_class.around(outer) do
      expect(described_class.current).to equal(outer)
      described_class.around(inner) { expect(described_class.current).to equal(inner) }
      expect(described_class.current).to equal(outer)
    end

    expect(described_class.current).to be_nil
  end

  it "does not grant nested work a second claim" do
    admission = described_class.new(tool:, reservation:)

    described_class.around(admission) do
      expect(described_class.current.claim(tool)).to be(true)
      expect(described_class.current.claim(tool)).to be(false)
    end
  end

  it "cannot be claimed by a different tool instance" do
    admission = described_class.new(tool:, reservation:)

    expect(admission.claim(Object.new)).to be(false)
    expect(admission.claim(tool)).to be(true)
  end
end
