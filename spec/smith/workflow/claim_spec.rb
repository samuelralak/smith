# frozen_string_literal: true

require "spec_helper"
require "stringio"
require "logger"

RSpec.describe Smith::Workflow::Claim do
  describe "load hygiene (no ActiveRecord on load path)" do
    it "module loads without referencing ::ActiveRecord at top level" do
      expect(Smith::Workflow::Claim).to be_a(Module)
    end

    it "Smith::Workflow is a Class and Smith::Workflow::Claim is a Module" do
      expect(Smith::Workflow).to be_a(Class)
      expect(Smith::Workflow::Claim).to be_a(Module)
    end

    it "raises AdapterUnavailable with a useful message when ::ActiveRecord is undefined" do
      hide_const("ActiveRecord")
      expect {
        described_class.atomic(double("model"), id: 1, from_statuses: ["queued"], transition_via: :mark_processing!)
      }.to raise_error(Smith::Workflow::Claim::AdapterUnavailable, /ActiveRecord/)

      expect {
        described_class.cas(double("model"), id: 1, from_statuses: ["queued"], to_status: "processing")
      }.to raise_error(Smith::Workflow::Claim::AdapterUnavailable, /ActiveRecord/)
    end

    it "AdapterUnavailable inherits from Smith::Error" do
      expect(Smith::Workflow::Claim::AdapterUnavailable.ancestors).to include(Smith::Error)
    end

    it "UnexpectedStatus carries model, id, observed_status accessors" do
      err = Smith::Workflow::Claim::UnexpectedStatus.new(model: double("M", name: "M"), id: 7, observed_status: "bogus")
      expect(err.id).to eq(7)
      expect(err.observed_status).to eq("bogus")
      expect(err.message).to include("bogus", "M#7")
    end
  end

  describe ".atomic (AASM event path)", :ar do
    let(:record) { ClaimableRecord.create!(status: "queued") }

    it "claims a :queued row by calling transition_via and returns the reloaded record" do
      allow_any_instance_of(ClaimableRecord).to receive(:mark_processing!).and_call_original

      result = described_class.atomic(
        ClaimableRecord, id: record.id,
        from_statuses: ["queued"], transition_via: :mark_processing!,
        terminal_statuses: ["processing", "ready"]
      )

      expect(result).to be_a(ClaimableRecord)
      expect(result.id).to eq(record.id)
      expect(result.status).to eq("processing")
    end

    it "actually invokes the transition method (AASM event spy)" do
      called = []
      ClaimableRecord.define_method(:mark_processing!) do
        called << id
        update_columns(status: "processing", updated_at: Time.now.utc)
      end

      described_class.atomic(
        ClaimableRecord, id: record.id,
        from_statuses: ["queued"], transition_via: :mark_processing!,
        terminal_statuses: []
      )

      expect(called).to eq([record.id])
    end

    it "returns nil when current status is in terminal_statuses" do
      record.update_columns(status: "ready")

      result = described_class.atomic(
        ClaimableRecord, id: record.id,
        from_statuses: ["queued"], transition_via: :mark_processing!,
        terminal_statuses: ["processing", "ready"]
      )

      expect(result).to be_nil
      expect(record.reload.status).to eq("ready")
    end

    it "raises UnexpectedStatus when status is outside from_statuses ∪ terminal_statuses" do
      record.update_columns(status: "bogus")

      expect {
        described_class.atomic(
          ClaimableRecord, id: record.id,
          from_statuses: ["queued"], transition_via: :mark_processing!,
          terminal_statuses: ["processing"]
        )
      }.to raise_error(Smith::Workflow::Claim::UnexpectedStatus) { |err|
        expect(err.id).to eq(record.id)
        expect(err.observed_status).to eq("bogus")
      }
    end

    it "returns nil silently on bogus status when on_unexpected_status: :ignore" do
      record.update_columns(status: "bogus")

      result = described_class.atomic(
        ClaimableRecord, id: record.id,
        from_statuses: ["queued"], transition_via: :mark_processing!,
        terminal_statuses: ["processing"],
        on_unexpected_status: :ignore
      )

      expect(result).to be_nil
    end

    it "logs and returns nil when on_unexpected_status: :log" do
      record.update_columns(status: "bogus")
      log_io = StringIO.new
      old_logger = Smith.config.logger
      Smith.config.logger = Logger.new(log_io)
      begin
        result = described_class.atomic(
          ClaimableRecord, id: record.id,
          from_statuses: ["queued"], transition_via: :mark_processing!,
          terminal_statuses: ["processing"],
          on_unexpected_status: :log
        )

        expect(result).to be_nil
        expect(log_io.string).to include("bogus", "ClaimableRecord")
      ensure
        Smith.config.logger = old_logger
      end
    end

    it "uses transaction_owner.transaction when provided, NOT model_class.transaction" do
      owner = Class.new do
        def self.transaction(&block)
          @called = true
          ClaimableRecord.transaction(&block)
        end

        def self.called?
          @called
        end
      end

      described_class.atomic(
        ClaimableRecord, id: record.id,
        from_statuses: ["queued"], transition_via: :mark_processing!,
        terminal_statuses: [],
        transaction_owner: owner
      )

      expect(owner.called?).to be true
    end

    it "idempotency: second call with the same id returns record-then-nil" do
      first = described_class.atomic(
        ClaimableRecord, id: record.id,
        from_statuses: ["queued"], transition_via: :mark_processing!,
        terminal_statuses: ["processing"]
      )
      second = described_class.atomic(
        ClaimableRecord, id: record.id,
        from_statuses: ["queued"], transition_via: :mark_processing!,
        terminal_statuses: ["processing"]
      )

      expect(first).not_to be_nil
      expect(second).to be_nil
    end

    it "raises ArgumentError on AASM model when transition_via is nil" do
      aasm_model = Class.new(ClaimableRecord)
      aasm_model.define_singleton_method(:aasm) { Object.new }

      expect {
        described_class.atomic(aasm_model, id: 1, from_statuses: ["queued"], transition_via: nil, terminal_statuses: [])
      }.to raise_error(ArgumentError, /AASM/)
    end

    it "raises ArgumentError on non-AASM model when transition_via is nil" do
      expect {
        described_class.atomic(ClaimableRecord, id: 1, from_statuses: ["queued"], transition_via: nil, terminal_statuses: [])
      }.to raise_error(ArgumentError, /transition_via/)
    end
  end

  describe ".cas (single UPDATE path)", :ar do
    let(:record) { ClaimableRecord.create!(status: "queued") }

    it "claims a row whose status is in from_statuses; returns the reloaded record" do
      result = described_class.cas(
        ClaimableRecord, id: record.id,
        from_statuses: ["queued"], to_status: "processing"
      )

      expect(result).to be_a(ClaimableRecord)
      expect(result.status).to eq("processing")
    end

    it "returns nil when rowcount == 0 (status no longer in from_statuses)" do
      record.update_columns(status: "processing")

      result = described_class.cas(
        ClaimableRecord, id: record.id,
        from_statuses: ["queued"], to_status: "processing"
      )

      expect(result).to be_nil
    end

    it "stamps updated_at_column with the injected now: lambda value" do
      stamp = Time.utc(2026, 1, 1, 12, 0, 0)
      result = described_class.cas(
        ClaimableRecord, id: record.id,
        from_statuses: ["queued"], to_status: "processing",
        now: -> { stamp }
      )

      expect(result.updated_at.utc.to_i).to eq(stamp.to_i)
    end

    it "supports multi-status from_statuses" do
      record.update_columns(status: "failed")

      result = described_class.cas(
        ClaimableRecord, id: record.id,
        from_statuses: ["queued", "failed", "scheduled"],
        to_status: "processing"
      )

      expect(result.status).to eq("processing")
    end

    it "idempotency: second call returns record-then-nil" do
      first = described_class.cas(ClaimableRecord, id: record.id, from_statuses: ["queued"], to_status: "processing")
      second = described_class.cas(ClaimableRecord, id: record.id, from_statuses: ["queued"], to_status: "processing")
      expect(first).not_to be_nil
      expect(second).to be_nil
    end
  end
end
