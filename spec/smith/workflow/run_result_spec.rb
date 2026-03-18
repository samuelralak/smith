# frozen_string_literal: true

RSpec.describe "Smith::Workflow run result contract" do
  let(:workflow_class) { require_const("Smith::Workflow") }

  it "returns a result object with the documented workflow summary surface" do
    workflow = with_stubbed_class("SpecRunResultWorkflow", workflow_class) do
      initial_state :idle

      define_method(:terminal?) do
        @terminal_checked ||= false
        return true if @terminal_checked

        @terminal_checked = true
        false
      end
    end.new

    result = workflow.run!

    %i[state output steps total_cost total_tokens].each do |method_name|
      expect(result).to respond_to(method_name), "expected run! result to implement ##{method_name}"
    end
  end

  it "raises MaxTransitionsExceeded and leaves the workflow in its current state" do
    workflow = with_stubbed_class("SpecBoundedWorkflow", workflow_class) do
      initial_state :idle
      max_transitions 1

      define_method(:terminal?) do
        @terminal_checks ||= 0
        @terminal_checks += 1
        @terminal_checks > 3
      end
    end.new

    expect { workflow.run! }.to raise_error(require_const("Smith::MaxTransitionsExceeded"))
    expect(workflow.state).to eq(:idle)
  end

  it "returns immediately when the workflow is already terminal" do
    workflow = with_stubbed_class("SpecImmediatelyTerminalWorkflow", workflow_class) do
      initial_state :idle

      define_method(:terminal?) do
        true
      end
    end.new

    result = workflow.run!

    expect(result.state).to eq(:idle)
    expect(result.steps).to eq([])
    expect(result.output).to be_nil
  end

  it "advances until terminal? becomes true" do
    workflow = with_stubbed_class("SpecAdvancingWorkflow", workflow_class) do
      initial_state :idle

      define_method(:terminal?) do
        @terminal_checks ||= 0
        @terminal_checks += 1
        @terminal_checks > 3
      end
    end.new

    workflow.run!

    expect(workflow.to_state[:step_count]).to eq(3)
    expect(workflow.state).to eq(:idle)
  end
end
