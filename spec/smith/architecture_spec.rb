# frozen_string_literal: true

RSpec.describe "smith architecture contract" do
  it "defines the top-level namespaces expected by the architecture" do
    %w[
      Smith::Agent
      Smith::Workflow
      Smith::Events
      Smith::Event
      Smith::Tool
      Smith::Guardrails
      Smith::Context
      Smith::Budget
      Smith::Artifacts
      Smith::Trace
      Smith::Errors
      Smith::Types
    ].each do |path|
      expect(fetch_const(path)).not_to be_nil, "expected #{path} to be defined"
    end
  end

  it "defines the typed scalar helpers used by documented event schemas" do
    %w[
      Smith::Types::String
      Smith::Types::Integer
    ].each do |path|
      expect(fetch_const(path)).not_to be_nil, "expected #{path} to be defined"
    end
  end

  it "defines the documented trace adapters and workflow persistence namespace" do
    %w[
      Smith::Trace::Memory
      Smith::Trace::Logger
      Smith::Trace::OpenTelemetry
      Smith::Workflow::Persistence
    ].each do |path|
      expect(fetch_const(path)).not_to be_nil, "expected #{path} to be defined"
    end
  end

  it "defines the documented error hierarchy" do
    base = require_const("Smith::Error")

    %w[
      Smith::BudgetExceeded
      Smith::DeadlineExceeded
      Smith::MaxTransitionsExceeded
      Smith::GuardrailFailed
      Smith::ToolGuardrailFailed
      Smith::ToolPolicyDenied
      Smith::AgentError
      Smith::WorkflowError
      Smith::SerializationError
    ].each do |path|
      error_class = require_const(path)
      expect(error_class).to be < base
    end
  end
end
