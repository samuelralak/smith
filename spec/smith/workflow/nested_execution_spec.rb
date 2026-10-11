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
    ledger.define_singleton_method(:reconcile!) do |reservation, actual_amount|
      key, reserved_amount = reservation.amounts.first
      observed << [:reconcile, key, reserved_amount, actual_amount]
      original_reconcile.call(reservation, actual_amount)
    end

    result = parent.run!

    expect(result.state).to eq(:done)

    entries = []
    entries << observed.pop until observed.empty?
    token_reconciles = entries.select { |e| e[1] == :total_tokens }
    expect(token_reconciles).not_to be_empty
    expect(token_reconciles).to all(satisfy { |e| e[3] >= 0 })
  end

  it "rolls child best-known cost and tokens into the parent run result totals" do
    original_pricing = Smith.config.pricing

    Smith.configure do |config|
      config.pricing = {
        "gpt-5-mini" => {
          input_cost_per_token: 0.01,
          output_cost_per_token: 0.02
        }
      }
    end

    child_agent = with_stubbed_class("SpecNestedCostAgent", agent_class) do
      register_as :spec_nested_cost_agent
      model "gpt-5-mini"
    end
    stub_agent(child_agent, "ok")

    child_class = with_stubbed_class("SpecNestedCostChild", workflow_class) do
      initial_state :idle
      state :done

      transition :work, from: :idle, to: :done do
        execute :spec_nested_cost_agent
      end
    end

    parent = with_stubbed_class("SpecNestedCostParent", workflow_class) do
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
    expect(result.total_cost).to eq(0.11)
    expect(result.total_tokens).to eq(8)
  ensure
    Smith.configure { |config| config.pricing = original_pricing }
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

    # The parent's earlier steps already spent its whole wall_clock budget.
    workflow = parent_class.new
    workflow.instance_variable_set(:@active_seconds, 120.0)

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

  describe "a child's failure in its parent" do
    def compute_child(name, &body)
      with_stubbed_class(name, workflow_class) do
        initial_state :idle

        transition :work, from: :idle, to: :done do
          compute(&body)
        end
      end
    end

    def parent_of(name, child, retry_classes: [], attempts: 2, **options)
      wall_clock = options[:wall_clock]
      backoff = options.fetch(:backoff, 0)
      with_stubbed_class(name, workflow_class) do
        initial_state :idle
        state :failed
        budget wall_clock: wall_clock if wall_clock

        transition :delegate, from: :idle, to: :done do
          workflow child
          retry_on(*retry_classes, attempts:, backoff:)
          on_failure :fail
        end
      end
    end

    it "reaches the parent unchanged when the child raises, and is retried when retryable" do
      calls = []
      child = compute_child("SpecNestedRaiseRetryChild") do |step|
        calls << 1
        step.fail!("busy", retryable: true) if calls.size == 1
      end

      result = parent_of("SpecNestedRaiseRetryParent", child).new.run!

      expect(result.state).to eq(:done)
      expect(calls.size).to eq(2)
    end

    it "keeps the child's error object and class, and matches retry_on by it at any depth" do
      calls = []
      grandchild = compute_child("SpecNestedDeepGrandchild") do |step|
        calls << 1
        step.fail!("busy") if calls.size == 1
      end
      child = with_stubbed_class("SpecNestedDeepChild", workflow_class) do
        initial_state :idle
        transition(:delegate, from: :idle, to: :done) { workflow grandchild }
      end

      result = parent_of("SpecNestedDeepParent", child, retry_classes: [Smith::DeterministicStepFailure]).new.run!

      expect(result.state).to eq(:done)
      expect(calls.size).to eq(2)
    end

    it "is not retried when the child's raised error is not retryable" do
      calls = []
      child = compute_child("SpecNestedFinalChild") do |step|
        calls << 1
        step.fail!("final")
      end

      result = parent_of("SpecNestedFinalParent", child).new.run!

      expect(result.state).to eq(:failed)
      expect(calls.size).to eq(1)
      expect(result.steps.first[:error]).to be_a(Smith::DeterministicStepFailure)
      expect(result.steps.first[:error].message).to eq("final")
    end

    it "is a non-retryable WorkflowError when the child routed its failure, so it is not retried" do
      calls = []
      child = with_stubbed_class("SpecNestedRoutedChild", workflow_class) do
        initial_state :idle
        state :failed

        transition :work, from: :idle, to: :done do
          compute do |step|
            calls << 1
            step.fail!("busy", retryable: true)
          end
          on_failure :fail
        end
      end

      result = parent_of("SpecNestedRoutedParent", child, attempts: 3).new.run!

      expect(result.state).to eq(:failed)
      expect(calls.size).to eq(1)
      error = result.steps.first[:error]
      expect(error.class).to eq(Smith::WorkflowError)
      expect(error.message).to eq("nested workflow failed: busy")
      expect(Smith::Errors.retryable?(error)).to be(false)
    end

    it "lets a non-Smith error the child raises through unchanged" do
      child = compute_child("SpecNestedPlainErrorChild") { |_step| raise ArgumentError, "bad input" }

      error = parent_of("SpecNestedPlainErrorParent", child).new.run!.steps.first[:error]

      expect(error).to be_a(ArgumentError)
      expect(error.message).to eq("bad input")
    end

    describe "after a tool ran in the child" do
      def tool_then_failing_child(name, effects, routed:)
        with_stubbed_class(name, workflow_class) do
          initial_state :idle
          state :failed

          transition :use_tool, from: :idle, to: :used do
            compute do |_step|
              Smith::Tool.current_tool_execution_tracker&.mark_started!
              effects << :charged
            end
          end

          transition :finish, from: :used, to: :done do
            compute { |step| step.fail!("busy", retryable: true) }
            on_failure :fail if routed
          end
        end
      end

      it "never retries the parent, whether the child raised or routed the failure" do
        [false, true].each do |routed|
          effects = []
          child = tool_then_failing_child("SpecNestedToolChild#{routed}", effects, routed:)

          result = parent_of("SpecNestedToolParent#{routed}", child, attempts: 3).new.run!

          expect(result.state).to eq(:failed)
          expect(effects).to eq([:charged])
          error = result.steps.first[:error]
          expect(error).to be_a(Smith::ToolOutcomeUncertain)
          expect(Smith::Errors.retry_forbidden?(error)).to be(true)
        end
      end

      it "leaves a failure record that restores and runs again" do
        effects = []
        child = tool_then_failing_child("SpecNestedToolRestoreChild", effects, routed: false)
        parent = parent_of("SpecNestedToolRestoreParent", child)
        workflow = parent.new
        workflow.run!

        restored = parent.from_state(JSON.parse(JSON.generate(workflow.to_state)))
        rerun = restored.run!

        expect(rerun.state).to eq(:failed)
        expect(rerun.last_error).to be_a(Smith::ToolOutcomeUncertain)
        expect(workflow.run!.state).to eq(:failed)
        expect(effects).to eq([:charged])
      end
    end

    it "rolls the raising child's usage into the parent on every attempt" do
      child_agent = with_stubbed_class("SpecNestedUsageAgent", agent_class) do
        register_as :spec_nested_usage_agent
        model "gpt-5-mini"
      end
      stub_agent(child_agent, "partial")
      child = with_stubbed_class("SpecNestedUsageChild", workflow_class) do
        initial_state :idle

        transition(:call, from: :idle, to: :called) { execute :spec_nested_usage_agent }
        transition(:fail_after, from: :called, to: :done) { compute { |step| step.fail!("busy", retryable: true) } }
      end

      result = parent_of("SpecNestedUsageParent", child, attempts: 2).new.run!

      expect(result.state).to eq(:failed)
      expect(result.total_tokens).to eq(16)
      expect(result.usage_entries.size).to eq(2)
    ensure
      Smith::Agent::Registry.delete(:spec_nested_usage_agent)
    end

    it "is not retried once the parent's wall-clock deadline has passed" do
      calls = []
      child = with_stubbed_class("SpecNestedDeadlineChild", workflow_class) do
        initial_state :idle

        transition(:slow, from: :idle, to: :slowed) do
          compute do |_step|
            calls << 1
            sleep 0.15
          end
        end
        transition(:after, from: :slowed, to: :done) { compute { |_step| nil } }
      end
      parent = parent_of("SpecNestedDeadlineParent", child, attempts: 4, wall_clock: 0.1, backoff: 0.3)

      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      result = parent.new.run!
      elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started

      expect(result.steps.first[:error]).to be_a(Smith::DeadlineExceeded)
      expect(calls.size).to eq(1)
      expect(elapsed).to be < 0.5
    end
  end
end
