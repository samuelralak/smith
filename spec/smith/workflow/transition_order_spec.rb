# frozen_string_literal: true

RSpec.describe "Smith::Workflow transition declaration order" do
  let(:workflow_class) { require_const("Smith::Workflow") }

  # `state :failed` auto-generates a :fail placeholder, allocating its order
  # number at that (early) moment. A later user-declared :fail must take its
  # own declaration position, or it shadows a same-origin primary transition
  # and run! executes the failure path first.
  it "a user-declared :fail does not shadow a same-origin primary declared before it" do
    executed = []
    workflow = with_stubbed_class("SpecFailOrderWorkflow", workflow_class) do
      initial_state :idle
      state :done
      state :failed

      transition :primary, from: :idle, to: :done
      transition :fail, from: :idle, to: :failed
    end.new
    workflow.define_singleton_method(:execute_transition_body) do |transition, **|
      executed << transition.name
      nil
    end

    workflow.advance!

    expect(executed).to eq([:primary])
    expect(workflow.state).to eq(:done)
  end

  it "a genuine user redefinition keeps its original declaration position" do
    executed = []
    workflow = with_stubbed_class("SpecRedefineOrderWorkflow", workflow_class) do
      initial_state :idle
      state :done
      state :reviewed

      transition :first, from: :idle, to: :done
      transition :second, from: :idle, to: :reviewed
      # Redefine :first after :second; it must stay first in origin order.
      transition :first, from: :idle, to: :done
    end.new
    workflow.define_singleton_method(:execute_transition_body) do |transition, **|
      executed << transition.name
      nil
    end

    workflow.advance!

    expect(executed).to eq([:first])
  end

  it "the generated :fail placeholder still exists when never redeclared" do
    workflow = with_stubbed_class("SpecGeneratedFailWorkflow", workflow_class) do
      initial_state :idle
      state :failed

      transition :go, from: :idle, to: :failed do
        on_failure :fail
      end
    end

    expect(workflow.find_transition(:fail)).not_to be_nil
    expect(workflow.find_transition(:fail).to).to eq(:failed)
  end

  it "subclasses inherit the generated-transition bookkeeping" do
    parent = with_stubbed_class("SpecFailOrderParentWorkflow", workflow_class) do
      initial_state :idle
      state :done
      state :failed
    end
    executed = []
    child = with_stubbed_class("SpecFailOrderChildWorkflow", parent) do
      transition :primary, from: :idle, to: :done
      transition :fail, from: :idle, to: :failed
    end.new
    child.define_singleton_method(:execute_transition_body) do |transition, **|
      executed << transition.name
      nil
    end

    child.advance!

    expect(executed).to eq([:primary])
  end
end
