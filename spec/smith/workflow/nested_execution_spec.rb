# frozen_string_literal: true

RSpec.describe "Smith::Workflow nested execution" do
  let(:agent_class) { require_const("Smith::Agent") }
  let(:workflow_class) { require_const("Smith::Workflow") }
  let(:workflow_error) { require_const("Smith::WorkflowError") }

  def stub_agent(klass, result)
    allow(klass).to receive(:chat) do
      chat = Object.new
      chat.define_singleton_method(:add_message) { |_msg| nil }
      chat.define_singleton_method(:complete) do
        Struct.new(:content, :input_tokens, :output_tokens).new(result, 5, 3)
      end
      chat
    end
  end

  it "returns child workflow final output as parent step output" do
    child_agent = with_stubbed_class("SpecNestedChildAgent", agent_class) do
      register_as :spec_nested_child_agent
      model "gpt-5-mini"
    end
    stub_agent(child_agent, "child result")

    child_class = with_stubbed_class("SpecNestedChildWorkflow", workflow_class) do
      initial_state :idle
      state :done

      transition :work, from: :idle, to: :done do
        execute :spec_nested_child_agent
      end
    end

    parent = with_stubbed_class("SpecNestedParentWorkflow", workflow_class) do
      initial_state :idle
      state :researched
      state :done

      transition :research, from: :idle, to: :researched do
        workflow child_class
      end

      transition :finish, from: :researched, to: :done
    end.new

    result = parent.run!

    expect(result.state).to eq(:done)
    expect(result.steps[0][:output]).to eq("child result")
    expect(result.steps.length).to eq(2)
  end

  it "routes parent through on_failure when child workflow fails" do
    child_agent = with_stubbed_class("SpecNestedFailChildAgent", agent_class) do
      register_as :spec_nested_fail_child_agent
      model "gpt-5-mini"
    end

    allow(child_agent).to receive(:chat) do
      chat = Object.new
      chat.define_singleton_method(:add_message) { |_msg| nil }
      chat.define_singleton_method(:complete) { raise StandardError, "provider down" }
      chat
    end

    child_class = with_stubbed_class("SpecNestedFailChildWorkflow", workflow_class) do
      initial_state :idle
      state :done
      state :failed

      transition :work, from: :idle, to: :done do
        execute :spec_nested_fail_child_agent
        on_failure :fail
      end
    end

    parent = with_stubbed_class("SpecNestedFailParentWorkflow", workflow_class) do
      initial_state :idle
      state :researched
      state :failed

      transition :research, from: :idle, to: :researched do
        workflow child_class
        on_failure :fail
      end
    end.new

    result = parent.run!

    expect(result.state).to eq(:failed)
    expect(result.steps.first[:error]).to be_a(workflow_error)
    expect(result.steps.first[:error].message).to include("nested workflow failed")
  end

  it "rejects workflow binding to a non-class" do
    expect do
      with_stubbed_class("SpecNestedNonClassWorkflow", workflow_class) do
        initial_state :idle
        state :done

        transition :research, from: :idle, to: :done do
          workflow "NotAClass"
        end
      end
    end.to raise_error(workflow_error, /must be a Class/)
  end

  it "rejects workflow binding to a non-workflow class" do
    expect do
      with_stubbed_class("SpecNestedNonWorkflowWorkflow", workflow_class) do
        initial_state :idle
        state :done

        transition :research, from: :idle, to: :done do
          workflow String
        end
      end
    end.to raise_error(workflow_error, /must be a Smith::Workflow subclass/)
  end

  it "rejects combining workflow with execute" do
    child_class = with_stubbed_class("SpecNestedDualChildWorkflow", workflow_class) do
      initial_state :idle
      state :done
    end

    agent = with_stubbed_class("SpecNestedDualAgent", agent_class) do
      register_as :spec_nested_dual_agent
      model "gpt-5-mini"
    end

    expect do
      with_stubbed_class("SpecNestedDualWorkflow", workflow_class) do
        initial_state :idle
        state :done

        transition :research, from: :idle, to: :done do
          execute :spec_nested_dual_agent
          workflow child_class
        end
      end
    end.to raise_error(workflow_error, /cannot declare both workflow and execute/)
  end

  it "rejects combining workflow with route" do
    child_class = with_stubbed_class("SpecNestedRouteChildWorkflow", workflow_class) do
      initial_state :idle
      state :done
    end

    classifier = with_stubbed_class("SpecNestedRouteClassifier", agent_class) do
      register_as :spec_nested_route_classifier
      model "gpt-5-mini"
    end

    expect do
      with_stubbed_class("SpecNestedRouteWorkflow", workflow_class) do
        initial_state :idle
        state :done

        transition :classify, from: :idle, to: :done do
          route :spec_nested_route_classifier,
                routes: { a: :b }, confidence_threshold: 0.5, fallback: :c
          workflow child_class
        end
      end
    end.to raise_error(workflow_error, /cannot declare both workflow and route/)
  end

  it "keeps parent step count parent-scoped" do
    child_agent = with_stubbed_class("SpecNestedStepCountAgent", agent_class) do
      register_as :spec_nested_step_count_agent
      model "gpt-5-mini"
    end
    stub_agent(child_agent, "ok")

    child_class = with_stubbed_class("SpecNestedStepCountChild", workflow_class) do
      initial_state :idle
      state :mid
      state :done

      transition :a, from: :idle, to: :mid do
        execute :spec_nested_step_count_agent
      end

      transition :b, from: :mid, to: :done do
        execute :spec_nested_step_count_agent
      end
    end

    parent = with_stubbed_class("SpecNestedStepCountParent", workflow_class) do
      initial_state :idle
      state :researched
      state :done

      transition :research, from: :idle, to: :researched do
        workflow child_class
      end

      transition :finish, from: :researched, to: :done
    end.new

    result = parent.run!

    expect(result.state).to eq(:done)
    expect(result.steps.length).to eq(2)
    expect(parent.instance_variable_get(:@step_count)).to eq(2)
  end

  it "shares parent budget ledger with child workflow" do
    child_agent = with_stubbed_class("SpecNestedBudgetAgent", agent_class) do
      register_as :spec_nested_budget_agent
      model "gpt-5-mini"
    end
    stub_agent(child_agent, "ok")

    child_class = with_stubbed_class("SpecNestedBudgetChild", workflow_class) do
      initial_state :idle
      state :done

      transition :work, from: :idle, to: :done do
        execute :spec_nested_budget_agent
      end
    end

    parent = with_stubbed_class("SpecNestedBudgetParent", workflow_class) do
      initial_state :idle
      state :researched
      state :done
      budget total_tokens: 5000

      transition :research, from: :idle, to: :researched do
        workflow child_class
      end

      transition :finish, from: :researched, to: :done
    end.new

    observed = Queue.new
    ledger = parent.ledger
    original_reconcile = ledger.method(:reconcile!)
    ledger.define_singleton_method(:reconcile!) do |key, ra, aa|
      observed << [:reconcile, key, ra, aa]
      original_reconcile.call(key, ra, aa)
    end

    result = parent.run!

    expect(result.state).to eq(:done)

    entries = []
    entries << observed.pop until observed.empty?
    token_reconciles = entries.select { |e| e[1] == :total_tokens }
    expect(token_reconciles).not_to be_empty
    expect(token_reconciles).to all(satisfy { |e| e[3] >= 0 })
  end

  it "inherits the parent wall_clock deadline for child execution" do
    child_agent = with_stubbed_class("SpecNestedDeadlineAgent", agent_class) do
      register_as :spec_nested_deadline_agent
      model "gpt-5-mini"
    end
    stub_agent(child_agent, "ok")

    child_class = with_stubbed_class("SpecNestedDeadlineChild", workflow_class) do
      initial_state :idle
      state :done

      transition :work, from: :idle, to: :done do
        execute :spec_nested_deadline_agent
      end
    end

    parent_class = with_stubbed_class("SpecNestedDeadlineParent", workflow_class) do
      initial_state :idle
      state :researched
      state :failed
      budget wall_clock: 60

      transition :research, from: :idle, to: :researched do
        workflow child_class
        on_failure :fail
      end
    end

    workflow = parent_class.new
    workflow.instance_variable_set(:@created_at, (Time.now.utc - 120).iso8601)

    result = workflow.run!

    expect(result.state).to eq(:failed)
    expect(result.steps.first[:error]).to be_a(require_const("Smith::DeadlineExceeded"))
    expect(result.steps.first[:error].message).to include("wall_clock deadline exceeded")
  end

  it "inherits the parent artifact scope without re-wrapping the scoped store" do
    original_store = Smith.config.artifact_store
    writes = []

    backend = Object.new
    backend.define_singleton_method(:store) do |data, content_type: "application/octet-stream", execution_namespace: nil|
      writes << { data: data, content_type: content_type, execution_namespace: execution_namespace }
      "backend-ref-#{writes.length}"
    end
    backend.define_singleton_method(:fetch) { |_ref| nil }
    backend.define_singleton_method(:expired) { |retention: nil, execution_namespace: nil| [] }

    Smith.configure do |config|
      config.artifact_store = backend
    end

    child_agent = with_stubbed_class("SpecNestedArtifactAgent", agent_class) do
      register_as :spec_nested_artifact_agent
      model "gpt-5-mini"

      define_method(:after_completion) do |_result, _context|
        { ref: Smith.artifacts.store("nested-artifact", content_type: "text/plain") }
      end
    end

    allow(child_agent).to receive(:chat) do
      chat = Object.new
      chat.define_singleton_method(:add_message) { |_msg| nil }
      chat.define_singleton_method(:complete) do
        Struct.new(:content, :input_tokens, :output_tokens).new("ok", 5, 3)
      end
      chat
    end

    child_class = with_stubbed_class("SpecNestedArtifactChild", workflow_class) do
      initial_state :idle
      state :done

      transition :work, from: :idle, to: :done do
        execute :spec_nested_artifact_agent
      end
    end

    parent = with_stubbed_class("SpecNestedArtifactParent", workflow_class) do
      initial_state :idle
      state :researched
      state :done

      transition :research, from: :idle, to: :researched do
        workflow child_class
      end

      transition :finish, from: :researched, to: :done
    end.new

    result = parent.run!
    execution_namespace = parent.to_state[:execution_namespace]

    expect(result.state).to eq(:done)
    expect(result.steps.first[:output]).to eq(ref: "#{execution_namespace}:backend-ref-1")
    expect(writes).to eq([{ data: "nested-artifact", content_type: "text/plain", execution_namespace: execution_namespace }])
  ensure
    Smith.configure do |config|
      config.artifact_store = original_store
    end
  end
end
