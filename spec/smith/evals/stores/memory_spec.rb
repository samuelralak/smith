# frozen_string_literal: true

require "smith/evals"

# The memory store passes the one store example group. It lives in one
# process, so a lease ends with it; the file store's specs cover a lease
# outliving no process (kill -9).
RSpec.describe Smith::Evals::Stores::Memory do
  let(:store) { described_class.new(clock: -> { EvalRecords::CLOCK_AT }) }
  let(:other_store) { described_class.new }

  def store_with(clock:) = described_class.new(clock:)

  it_behaves_like "an eval store"
  it_behaves_like "a tuning store"

  it "keeps nothing between two stores" do
    store.create_record(scope: EvalRecords.scope, header: EvalRecords.header)

    expect(other_store.read_header(scope: EvalRecords.scope, eval_run_id: EvalRecords.eval_run_id)).to be_nil
  end

  it "refuses a clock that cannot be called" do
    expect { described_class.new(clock: Time.now) }.to raise_error(ArgumentError, /clock/)
  end
end
