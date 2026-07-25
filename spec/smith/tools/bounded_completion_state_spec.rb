# frozen_string_literal: true

RSpec.describe Smith::Tool::BoundedCompletionState do
  subject(:state) { described_class.new(allowance: allowance) }

  let(:allowance) { Smith::Tool::CallAllowance.new(2, on_exhaustion: :complete) }

  it "permits one active finalization attempt" do
    state.request_finalization!

    expect(state).to be_finalization_required
    expect(state.begin_finalization).to eq(:started)
    expect(state).to be_finalization_started
    expect(state.begin_finalization).to eq(:active)
  end

  it "returns a failed attempt to the required state" do
    state.request_finalization!
    state.begin_finalization
    state.abort_finalization!

    expect(state).not_to be_finalization_started
    expect(state).to be_finalization_required
  end
end
