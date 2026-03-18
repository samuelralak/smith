# frozen_string_literal: true

RSpec.describe "Smith::Workflow run result contract" do
  let(:workflow_class) { require_const("Smith::Workflow") }

  it "returns a result object with the documented workflow summary surface" do
    workflow = with_stubbed_class("SpecRunResultWorkflow", workflow_class) do
      initial_state :idle
      state :done

      transition :go, from: :idle, to: :done
    end.new

    result = workflow.run!

    %i[state output steps total_cost total_tokens].each do |method_name|
      expect(result).to respond_to(method_name), "expected run! result to implement ##{method_name}"
    end
  end

  it "raises MaxTransitionsExceeded and leaves the workflow in its current state" do
    workflow = with_stubbed_class("SpecBoundedWorkflow", workflow_class) do
      initial_state :idle
      state :step_one
      state :step_two
      max_transitions 1

      transition :first, from: :idle, to: :step_one
      transition :second, from: :step_one, to: :step_two
    end.new

    expect { workflow.run! }.to raise_error(require_const("Smith::MaxTransitionsExceeded"))
    expect(workflow.state).to eq(:step_one)
  end

  it "returns immediately when the workflow is already terminal" do
    workflow = with_stubbed_class("SpecImmediatelyTerminalWorkflow", workflow_class) do
      initial_state :idle
    end.new

    result = workflow.run!

    expect(result.state).to eq(:idle)
    expect(result.steps).to eq([])
    expect(result.output).to be_nil
  end

  it "advances through transitions until no further transition exists" do
    workflow = with_stubbed_class("SpecAdvancingWorkflow", workflow_class) do
      initial_state :idle
      state :step_one
      state :step_two
      state :done

      transition :first, from: :idle, to: :step_one
      transition :second, from: :step_one, to: :step_two
      transition :third, from: :step_two, to: :done
    end.new

    result = workflow.run!

    expect(workflow.to_state[:step_count]).to eq(3)
    expect(workflow.state).to eq(:done)
    expect(result.steps.length).to eq(3)
    expect(result.state).to eq(:done)
  end

  it "does not treat the wildcard fail transition as a normal next step" do
    workflow = with_stubbed_class("SpecNoWildcardNormalFlowWorkflow", workflow_class) do
      initial_state :idle
      state :done
      state :failed

      transition :finish, from: :idle, to: :done
    end.new

    result = workflow.run!

    expect(workflow.state).to eq(:done)
    expect(result.state).to eq(:done)
    expect(result.steps.map { |step| step[:transition] }).to eq([:finish])
  end

  it "uses on_success to select the named next transition when multiple transitions share a state" do
    workflow = with_stubbed_class("SpecOnSuccessWorkflow", workflow_class) do
      initial_state :idle
      state :ready
      state :done
      state :alternate_done

      transition :start, from: :idle, to: :ready do
        on_success :finish
      end

      transition :alternate, from: :ready, to: :alternate_done
      transition :finish, from: :ready, to: :done
    end.new

    result = workflow.run!

    expect(workflow.state).to eq(:done)
    expect(result.steps.map { |step| step[:transition] }).to eq(%i[start finish])
  end
end
