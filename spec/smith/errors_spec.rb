# frozen_string_literal: true

require "spec_helper"

RSpec.describe Smith::Errors do
  describe ".retryable?" do
    it "returns false for nil" do
      expect(described_class.retryable?(nil)).to be false
    end

    it "returns true for AgentError" do
      expect(described_class.retryable?(Smith::AgentError.new("boom"))).to be true
    end

    it "returns true for DeadlineExceeded" do
      expect(described_class.retryable?(Smith::DeadlineExceeded.new("deadline"))).to be true
    end

    it "returns true for BlankAgentOutputError (subclass of AgentError)" do
      err = Smith::BlankAgentOutputError.new(agent_name: :writer, model_used: "claude-opus-4-8")
      expect(described_class.retryable?(err)).to be true
    end

    it "honors retryable: true on DeterministicStepFailure" do
      err = Smith::DeterministicStepFailure.new("transient", retryable: true)
      expect(described_class.retryable?(err)).to be true
    end

    it "honors retryable: false on DeterministicStepFailure" do
      err = Smith::DeterministicStepFailure.new("permanent", retryable: false)
      expect(described_class.retryable?(err)).to be false
    end

    it "treats DeterministicStepFailure without explicit retryable as terminal" do
      err = Smith::DeterministicStepFailure.new("unknown")
      expect(described_class.retryable?(err)).to be false
    end

    it "honors retryable: true on ToolGuardrailFailed" do
      err = Smith::ToolGuardrailFailed.new("policy fetch transient", retryable: true)
      expect(described_class.retryable?(err)).to be true
    end

    it "treats ToolGuardrailFailed without explicit retryable as terminal" do
      err = Smith::ToolGuardrailFailed.new("policy denied")
      expect(described_class.retryable?(err)).to be false
    end

    it "returns false for WorkflowError" do
      expect(described_class.retryable?(Smith::WorkflowError.new("logic error"))).to be false
    end

    it "returns false for BudgetExceeded" do
      expect(described_class.retryable?(Smith::BudgetExceeded.new("budget"))).to be false
    end

    it "returns false for GuardrailFailed" do
      expect(described_class.retryable?(Smith::GuardrailFailed.new("guardrail"))).to be false
    end

    it "returns false for non-Smith errors (host classifier territory)" do
      expect(described_class.retryable?(StandardError.new("foreign"))).to be false
      expect(described_class.retryable?(RuntimeError.new("foreign"))).to be false
    end

    it "returns false for PersistenceIOError (host policy decides retry)" do
      err = Smith::PersistenceIOError.new(operation: :store, cause: RuntimeError.new("conn"))
      expect(described_class.retryable?(err)).to be false
    end
  end

  describe ".retryable_classes" do
    it "lists the always-retryable classes" do
      expect(described_class.retryable_classes).to contain_exactly(
        Smith::AgentError, Smith::DeadlineExceeded
      )
    end

    it "excludes retryable-bearing families (classification depends on the attribute)" do
      expect(described_class.retryable_classes).not_to include(Smith::DeterministicStepFailure)
      expect(described_class.retryable_classes).not_to include(Smith::ToolGuardrailFailed)
    end

    it "returns a frozen array" do
      expect(described_class.retryable_classes).to be_frozen
    end
  end
end
