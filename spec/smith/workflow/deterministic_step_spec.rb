# frozen_string_literal: true

require "json"

RSpec.describe "Smith::Workflow deterministic step contract" do
  let(:workflow_class) { require_const("Smith::Workflow") }
  let(:agent_class) { require_const("Smith::Agent") }
  let(:context_class) { require_const("Smith::Context") }

  # ---------------------------------------------------------------------------
  # DSL contract
  # ---------------------------------------------------------------------------

  describe "DSL" do
    it "accepts a compute block on a transition" do
      klass = with_stubbed_class("SpecComputeWorkflow", workflow_class) do
        initial_state :idle
        state :done

        transition :check, from: :idle, to: :done do
          compute { |_step| }
        end
      end

      transition = klass.find_transition(:check)
      expect(transition.deterministic?).to be true
      expect(transition.deterministic_kind).to eq(:compute)
    end

    it "accepts a run block on a transition" do
      klass = with_stubbed_class("SpecRunWorkflow", workflow_class) do
        initial_state :idle
        state :done

        transition :normalize, from: :idle, to: :done do
          run { |_step| }
        end
      end

      transition = klass.find_transition(:normalize)
      expect(transition.deterministic?).to be true
      expect(transition.deterministic_kind).to eq(:run)
    end

    it "accepts route annotations on deterministic transitions" do
      klass = with_stubbed_class("SpecDeterministicRoutesWorkflow", workflow_class) do
        initial_state :idle
        state :checked
        state :done

        transition "check", from: :idle, to: :checked do
          compute(routes: [:finish, "repair"]) { |step| step.read_context(:noop) }
        end

        transition :finish, from: :checked, to: :done do
          run { |step| step.read_context(:noop) }
        end

        transition "repair", from: :checked, to: :done do
          run { |step| step.read_context(:noop) }
        end
      end

      transition = klass.find_transition("check")

      expect(transition.deterministic_routes).to eq([:finish, "repair"])
      expect(transition.deterministic_routes).to be_frozen
      expect(transition.deterministic_routes.last).to be_frozen
    end

    it "rejects malformed deterministic route annotations" do
      expect {
        with_stubbed_class("SpecDeterministicRoutesTypeWorkflow", workflow_class) do
          initial_state :idle
          state :done

          transition :check, from: :idle, to: :done do
            compute(routes: :finish) { |step| step.read_context(:noop) }
          end
        end
      }.to raise_error(Smith::WorkflowError, /deterministic routes must be an Array/)

      expect {
        with_stubbed_class("SpecDeterministicRoutesDuplicateWorkflow", workflow_class) do
          initial_state :idle
          state :done

          transition :check, from: :idle, to: :done do
            run(routes: [:finish, :finish]) { |step| step.read_context(:noop) }
          end
        end
      }.to raise_error(Smith::WorkflowError, /deterministic route .* is duplicated/)
    end

    it "rejects compute + execute" do
      expect {
        with_stubbed_class("SpecComputeExecuteWorkflow", workflow_class) do
          initial_state :idle
          state :done

          transition :check, from: :idle, to: :done do
            execute :some_agent
            compute { |_step| }
          end
        end
      }.to raise_error(Smith::WorkflowError, /compute\/run and execute/)
    end

    it "rejects execute + compute (reverse order)" do
      expect {
        with_stubbed_class("SpecExecuteComputeWorkflow", workflow_class) do
          initial_state :idle
          state :done

          transition :check, from: :idle, to: :done do
            compute { |_step| }
            execute :some_agent
          end
        end
      }.to raise_error(Smith::WorkflowError, /execute and compute\/run/)
    end

    it "rejects compute + route" do
      expect {
        with_stubbed_class("SpecComputeRouteWorkflow", workflow_class) do
          initial_state :idle
          state :done

          transition :check, from: :idle, to: :done do
            route :some_agent, routes: { done: :finish }, confidence_threshold: 0.5, fallback: :finish
            compute { |_step| }
          end
        end
      }.to raise_error(Smith::WorkflowError, /compute\/run and route/)
    end

    it "rejects compute + run (two deterministic blocks)" do
      expect {
        with_stubbed_class("SpecComputeRunWorkflow", workflow_class) do
          initial_state :idle
          state :done

          transition :check, from: :idle, to: :done do
            compute { |_step| }
            run { |_step| }
          end
        end
      }.to raise_error(Smith::WorkflowError, /compute and run/)
    end

    it "rejects route + compute (reverse order)" do
      expect {
        with_stubbed_class("SpecRouteComputeWorkflow", workflow_class) do
          initial_state :idle
          state :done

          transition :check, from: :idle, to: :done do
            compute { |_step| }
            route :some_agent, routes: {}, confidence_threshold: 0.5, fallback: :fail
          end
        end
      }.to raise_error(Smith::WorkflowError, /route and compute\/run/)
    end

    it "rejects compute + workflow (both orders)" do
      expect {
        child = with_stubbed_class("SpecChildWorkflow", workflow_class) do
          initial_state :idle
          state :done
          transition :finish, from: :idle, to: :done
        end

        with_stubbed_class("SpecComputeWorkflowConflict", workflow_class) do
          initial_state :idle
          state :done

          transition :check, from: :idle, to: :done do
            compute { |_step| }
            workflow child
          end
        end
      }.to raise_error(Smith::WorkflowError, /workflow and compute\/run/)
    end

    it "rejects compute + optimize" do
      schema = Struct.new(:required_keys).new([:accept])

      expect {
        with_stubbed_class("SpecComputeOptimizeWorkflow", workflow_class) do
          initial_state :idle
          state :done

          transition :check, from: :idle, to: :done do
            compute { |_step| }
            optimize generator: :g, evaluator: :e, max_rounds: 3, evaluator_schema: schema
          end
        end
      }.to raise_error(Smith::WorkflowError, /optimize and compute\/run/)
    end

    it "rejects optimize + compute (reverse order)" do
      schema = Struct.new(:required_keys).new([:accept])

      expect {
        with_stubbed_class("SpecOptimizeComputeWorkflow", workflow_class) do
          initial_state :idle
          state :done

          transition :check, from: :idle, to: :done do
            optimize generator: :g, evaluator: :e, max_rounds: 3, evaluator_schema: schema
            compute { |_step| }
          end
        end
      }.to raise_error(Smith::WorkflowError, /compute\/run and optimize/)
    end

    it "rejects compute + orchestrate" do
      schema = Struct.new(:required_keys).new([:key])

      expect {
        with_stubbed_class("SpecComputeOrchestrateWorkflow", workflow_class) do
          initial_state :idle
          state :done

          transition :check, from: :idle, to: :done do
            compute { |_step| }
            orchestrate orchestrator: :o, worker: :w, max_workers: 2, max_delegation_rounds: 3,
                        task_schema: schema, worker_output_schema: schema, final_output_schema: schema
          end
        end
      }.to raise_error(Smith::WorkflowError, /orchestrate and compute\/run/)
    end

    it "rejects orchestrate + compute (reverse order)" do
      schema = Struct.new(:required_keys).new([:key])

      expect {
        with_stubbed_class("SpecOrchestrateComputeWorkflow", workflow_class) do
          initial_state :idle
          state :done

          transition :check, from: :idle, to: :done do
            orchestrate orchestrator: :o, worker: :w, max_workers: 2, max_delegation_rounds: 3,
                        task_schema: schema, worker_output_schema: schema, final_output_schema: schema
            compute { |_step| }
          end
        end
      }.to raise_error(Smith::WorkflowError, /compute\/run and orchestrate/)
    end

    it "rejects compute without a block" do
      expect {
        with_stubbed_class("SpecComputeNoBlockWorkflow", workflow_class) do
          initial_state :idle
          state :done

          transition :check, from: :idle, to: :done do
            compute
          end
        end
      }.to raise_error(Smith::WorkflowError, /compute requires a block/)
    end

    it "rejects run without a block" do
      expect {
        with_stubbed_class("SpecRunNoBlockWorkflow", workflow_class) do
          initial_state :idle
          state :done

          transition :check, from: :idle, to: :done do
            run
          end
        end
      }.to raise_error(Smith::WorkflowError, /run requires a block/)
    end

    it "detects deterministic route duplicates in normalized linear time" do
      expect do
        with_stubbed_class("SpecDuplicateNormalizedRoutesWorkflow", workflow_class) do
          initial_state :idle
          state :done

          transition :check, from: :idle, to: :done do
            compute(routes: %w[finish finish]) { |step| step.read_context(:noop) }
          end
        end
      end.to raise_error(Smith::WorkflowError, /deterministic route "finish" is duplicated/)
    end
  end

  # ---------------------------------------------------------------------------
  # Runtime behavior
  # ---------------------------------------------------------------------------

  describe "runtime" do
    it "executes a compute block and advances state" do
      klass = with_stubbed_class("SpecComputeRuntimeWorkflow", workflow_class) do
        initial_state :idle
        state :verified
        state :done

        transition :verify, from: :idle, to: :verified do
          compute { |_step| }
        end

        transition :finish, from: :verified, to: :done do
          compute { |_step| }
        end
      end

      workflow = klass.new
      result = workflow.run!

      expect(result.state).to eq(:done)
      expect(result.steps.length).to eq(2)
    end

    it "provides read accessors on the step object" do
      observed = {}

      klass = with_stubbed_class("SpecComputeReadWorkflow", workflow_class) do
        initial_state :idle
        state :done

        transition :check, from: :idle, to: :done do
          compute do |step|
            observed[:context] = step.context
            observed[:current_state] = step.current_state
            observed[:transition_name] = step.transition_name
            observed[:tool_results] = step.tool_results
            observed[:session_messages] = step.session_messages
            observed[:last_output] = step.last_output
            observed[:output] = step.output
            observed[:read_context] = step.read_context(:topic)
          end
        end
      end

      klass.new(context: { topic: "testing" }).run!

      expect(observed[:context]).to eq(topic: "testing")
      expect(observed[:current_state]).to eq(:idle)
      expect(observed[:transition_name]).to eq(:check)
      expect(observed[:tool_results]).to eq([])
      expect(observed[:session_messages]).to eq([])
      expect(observed[:last_output]).to be_nil
      expect(observed[:output]).to be_nil
      expect(observed[:read_context]).to eq("testing")
    end

    it "rejects named deterministic routes whose from state does not match the live workflow state" do
      observed = {}

      klass = with_stubbed_class("SpecComputeCurrentStateMismatchWorkflow", workflow_class) do
        initial_state :idle
        state :verified
        state :other
        state :done

        transition :verify, from: :idle, to: :verified do
          compute { |step| step.read_context(:noop) }
          on_success :finish
        end

        transition :finish, from: :other, to: :done do
          compute { |step| observed[:current_state] = step.current_state }
        end
      end

      expect { klass.new.run! }
        .to raise_error(Smith::WorkflowError, /cannot run from state :verified/)

      expect(observed).to be_empty
    end

    it "extracts last_output from session messages" do
      observed_output = nil

      klass = with_stubbed_class("SpecComputeLastOutputWorkflow", workflow_class) do
        initial_state :idle
        state :done

        transition :check, from: :idle, to: :done do
          compute { |step| observed_output = step.last_output }
        end
      end

      workflow = klass.new
      workflow.instance_variable_set(:@session_messages, [
        { role: :user, content: "hello" },
        { role: :assistant, content: "first response" },
        { role: :user, content: "followup" },
        { role: :assistant, content: "second response" }
      ])
      workflow.run!

      expect(observed_output).to eq("second response")
    end

    it "writes context via write_context" do
      klass = with_stubbed_class("SpecRunWriteContextWorkflow", workflow_class) do
        initial_state :idle
        state :done

        transition :normalize, from: :idle, to: :done do
          run do |step|
            step.write_context(:result, { quality: :high })
          end
        end
      end

      workflow = klass.new
      result = workflow.run!

      expect(result.context[:result]).to eq(quality: :high)
    end

    it "overwrites context when write_context is called twice with the same key" do
      klass = with_stubbed_class("SpecOverwriteContextWorkflow", workflow_class) do
        initial_state :idle
        state :done

        transition :normalize, from: :idle, to: :done do
          run do |step|
            step.write_context(:data, "first")
            step.write_context(:data, "second")
          end
        end
      end

      result = klass.new.run!
      expect(result.context[:data]).to eq("second")
    end

    it "writes a workflow outcome via write_outcome" do
      klass = with_stubbed_class("SpecWriteOutcomeWorkflow", workflow_class) do
        initial_state :idle
        state :done

        transition :prepare, from: :idle, to: :done do
          run do |step|
            step.write_outcome(kind: :artifact_ready, payload: { title: "Test artifact" })
          end
        end
      end

      result = klass.new.run!

      expect(result.outcome).to eq(kind: :artifact_ready, payload: { title: "Test artifact" })
      expect(result.outcome_kind).to eq(:artifact_ready)
      expect(result.outcome_payload).to eq(title: "Test artifact")
    end

    it "rejects non-Symbol kinds in write_outcome" do
      klass = with_stubbed_class("SpecWriteOutcomeBadKindWorkflow", workflow_class) do
        initial_state :idle
        state :done
        state :failed

        transition :prepare, from: :idle, to: :done do
          run { |step| step.write_outcome(kind: "artifact_ready", payload: { title: "Test artifact" }) }
          on_failure :fail
        end
      end

      result = klass.new.run!

      expect(result.state).to eq(:failed)
      expect(result.last_error.message).to include("write_outcome kind must be a Symbol")
    end

    it "raises on double write_outcome" do
      klass = with_stubbed_class("SpecDoubleOutcomeWorkflow", workflow_class) do
        initial_state :idle
        state :done
        state :failed

        transition :prepare, from: :idle, to: :done do
          run do |step|
            step.write_outcome(kind: :artifact_ready, payload: { title: "First" })
            step.write_outcome(kind: :artifact_ready, payload: { title: "Second" })
          end
          on_failure :fail
        end
      end

      result = klass.new.run!

      expect(result.state).to eq(:failed)
      expect(result.last_error.message).to include("write_outcome already called")
    end

    it "discards the block return value" do
      klass = with_stubbed_class("SpecDiscardReturnWorkflow", workflow_class) do
        initial_state :idle
        state :done

        transition :check, from: :idle, to: :done do
          compute { |_step| "this should be ignored" }
        end
      end

      workflow = klass.new
      result = workflow.run!

      expect(result.output).to be_nil
      expect(result.steps.first[:output]).to be_nil
    end

    it "rejects non-Symbol keys in write_context" do
      klass = with_stubbed_class("SpecRunBadKeyWorkflow", workflow_class) do
        initial_state :idle
        state :done
        state :failed

        transition :normalize, from: :idle, to: :done do
          run { |step| step.write_context("bad_key", "value") }
          on_failure :fail
        end
      end

      workflow = klass.new
      result = workflow.run!

      expect(result.state).to eq(:failed)
      expect(result.last_error.message).to include("write_context key must be a Symbol")
    end

    it "route_to overrides on_success" do
      klass = with_stubbed_class("SpecRouteToOverrideWorkflow", workflow_class) do
        initial_state :idle
        state :verified
        state :alternate
        state :done

        transition :verify, from: :idle, to: :verified do
          compute { |step| step.route_to(:alternate_path) }
          on_success :default_path
        end

        transition :default_path, from: :verified, to: :done do
          compute { |_step| }
        end

        transition :alternate_path, from: :verified, to: :done do
          compute { |_step| }
        end
      end

      workflow = klass.new
      result = workflow.run!

      expect(result.state).to eq(:done)
      transitions = result.steps.map { |s| s[:transition] }
      expect(transitions).to eq(%i[verify alternate_path])
    end

    it "rejects route_to targets outside declared deterministic routes" do
      klass = with_stubbed_class("SpecUndeclaredDeterministicRouteWorkflow", workflow_class) do
        initial_state :idle
        state :verified
        state :done
        state :failed

        transition :verify, from: :idle, to: :verified do
          compute(routes: [:finish]) { |step| step.route_to(:repair) }
          on_failure :fail
        end

        transition :finish, from: :verified, to: :done do
          compute { |step| step.read_context(:noop) }
        end

        transition :repair, from: :verified, to: :done do
          compute { |step| step.read_context(:noop) }
        end
      end

      result = klass.new.run!

      expect(result.state).to eq(:failed)
      expect(result.last_error.message).to include("route_to :repair is not declared in deterministic routes")
    end

    it "requires route_to targets to match deterministic route annotations exactly" do
      klass = with_stubbed_class("SpecExactDeterministicRouteWorkflow", workflow_class) do
        initial_state :idle
        state :verified
        state :done
        state :failed

        transition :verify, from: :idle, to: :verified do
          compute(routes: ["finish"]) { |step| step.route_to(:finish) }
          on_failure :fail
        end

        transition "finish", from: :verified, to: :done do
          compute { |step| step.read_context(:noop) }
        end
      end

      result = klass.new.run!

      expect(result.state).to eq(:failed)
      expect(result.last_error.message).to include("route_to :finish is not declared in deterministic routes")
    end

    it "uses on_success when route_to is not called" do
      klass = with_stubbed_class("SpecOnSuccessWorkflow", workflow_class) do
        initial_state :idle
        state :verified
        state :done

        transition :verify, from: :idle, to: :verified do
          compute { |_step| }
          on_success :finish
        end

        transition :finish, from: :verified, to: :done do
          compute { |_step| }
        end
      end

      workflow = klass.new
      result = workflow.run!

      transitions = result.steps.map { |s| s[:transition] }
      expect(transitions).to eq(%i[verify finish])
    end

    it "raises on double route_to" do
      klass = with_stubbed_class("SpecDoubleRouteWorkflow", workflow_class) do
        initial_state :idle
        state :done
        state :failed

        transition :check, from: :idle, to: :done do
          compute do |step|
            step.route_to(:first)
            step.route_to(:second)
          end
          on_failure :fail
        end
      end

      workflow = klass.new
      result = workflow.run!

      expect(result.state).to eq(:failed)
      expect(result.last_error.message).to include("route_to already called")
    end

    it "fails via step.fail! with metadata" do
      klass = with_stubbed_class("SpecFailBangWorkflow", workflow_class) do
        initial_state :idle
        state :done
        state :failed

        transition :verify, from: :idle, to: :done do
          compute do |step|
            step.fail!("research unavailable", retryable: true, kind: :tool_outage, details: { source: :web })
          end
          on_failure :fail
        end
      end

      workflow = klass.new
      result = workflow.run!

      expect(result.state).to eq(:failed)
      expect(result.failed_transition).to eq(:verify)

      error = result.failure_detail[:error]
      expect(error).to be_a(Smith::DeterministicStepFailure)
      expect(error.message).to eq("research unavailable")
      expect(error.retryable).to be true
      expect(error.kind).to eq(:tool_outage)
      expect(error.details).to eq(source: :web)
    end

    it "handles raised exceptions the same as agent failures" do
      klass = with_stubbed_class("SpecRaisedExceptionWorkflow", workflow_class) do
        initial_state :idle
        state :done
        state :failed

        transition :verify, from: :idle, to: :done do
          compute { |_step| raise "unexpected error" }
          on_failure :fail
        end
      end

      workflow = klass.new
      result = workflow.run!

      expect(result.state).to eq(:failed)
      expect(result.last_error.message).to eq("unexpected error")
    end

    it "does not append output to session_messages" do
      klass = with_stubbed_class("SpecNoOutputWorkflow", workflow_class) do
        initial_state :idle
        state :done

        transition :check, from: :idle, to: :done do
          compute { |_step| }
        end
      end

      workflow = klass.new
      workflow.instance_variable_set(:@session_messages, [{ role: :user, content: "hello" }])
      workflow.run!

      expect(workflow.session_messages).to eq([{ role: :user, content: "hello" }])
    end

    it "does not consume budget" do
      klass = with_stubbed_class("SpecNoBudgetWorkflow", workflow_class) do
        initial_state :idle
        state :done
        budget total_cost: 1.0, token_limit: 1000

        transition :check, from: :idle, to: :done do
          compute { |_step| }
        end
      end

      workflow = klass.new
      result = workflow.run!

      expect(result.total_cost).to eq(0.0)
      expect(result.total_tokens).to eq(0)
    end

    it "enforces deadlines" do
      klass = with_stubbed_class("SpecDeadlineWorkflow", workflow_class) do
        initial_state :idle
        state :done
        state :failed
        budget wall_clock: 0

        transition :check, from: :idle, to: :done do
          compute { |_step| }
          on_failure :fail
        end
      end

      workflow = klass.new
      # Force created_at to the past so deadline is already exceeded
      workflow.instance_variable_set(:@created_at, (Time.now.utc - 10).iso8601)

      result = workflow.run!

      expect(result.state).to eq(:failed)
      expect(result.last_error).to be_a(Smith::DeadlineExceeded)
    end

    it "fails loudly when route_to targets a non-existent transition with full attribution" do
      klass = with_stubbed_class("SpecMissingRouteWorkflow", workflow_class) do
        initial_state :idle
        state :verified
        state :done
        state :failed

        transition :verify, from: :idle, to: :verified do
          compute { |step| step.route_to(:missing) }
          on_failure :fail
        end

        transition :finish, from: :verified, to: :done do
          compute { |_step| }
        end
      end

      workflow = klass.new
      result = workflow.run!

      expect(result.state).to eq(:failed)

      error = result.last_error
      expect(error).to be_a(Smith::UnresolvedTransitionError)
      expect(error.message).to include("unresolved transition :missing")
      expect(error.requested_name).to eq(:missing)

      expect(result.failed_transition).to eq(:missing)
      expect(result.failure_detail[:from]).to eq(:verified)
      expect(result.failure_detail[:to]).to eq(:failed)
    end

    it "fails loudly when on_success targets a non-existent transition with full attribution" do
      klass = with_stubbed_class("SpecMissingOnSuccessWorkflow", workflow_class) do
        initial_state :idle
        state :verified
        state :done
        state :failed

        transition :verify, from: :idle, to: :verified do
          compute { |_step| }
          on_success :missing
          on_failure :fail
        end

        transition :finish, from: :verified, to: :done do
          compute { |_step| }
        end
      end

      workflow = klass.new
      result = workflow.run!

      expect(result.state).to eq(:failed)

      error = result.last_error
      expect(error).to be_a(Smith::UnresolvedTransitionError)
      expect(error.message).to include("unresolved transition :missing")
      expect(error.requested_name).to eq(:missing)

      expect(result.failed_transition).to eq(:missing)
      expect(result.failure_detail[:from]).to eq(:verified)
      expect(result.failure_detail[:to]).to eq(:failed)
    end

    it "raises UnresolvedTransitionError when route_to targets missing transition and no failed state exists" do
      klass = with_stubbed_class("SpecNoFailStateMissingRoute", workflow_class) do
        initial_state :idle
        state :verified
        state :done

        transition :verify, from: :idle, to: :verified do
          compute { |step| step.route_to(:missing) }
        end

        transition :finish, from: :verified, to: :done do
          compute { |_step| }
        end
      end

      expect { klass.new.run! }.to raise_error(Smith::UnresolvedTransitionError, /unresolved transition :missing/)
    end

    it "raises UnresolvedTransitionError when on_success targets missing transition and no failed state exists" do
      klass = with_stubbed_class("SpecNoFailStateMissingOnSuccess", workflow_class) do
        initial_state :idle
        state :verified
        state :done

        transition :verify, from: :idle, to: :verified do
          compute { |_step| }
          on_success :missing
        end

        transition :finish, from: :verified, to: :done do
          compute { |_step| }
        end
      end

      expect { klass.new.run! }.to raise_error(Smith::UnresolvedTransitionError, /unresolved transition :missing/)
    end

    it "read_context reflects pending writes within the same step" do
      observed = {}

      klass = with_stubbed_class("SpecReadAfterWriteWorkflow", workflow_class) do
        initial_state :idle
        state :done

        transition :check, from: :idle, to: :done do
          run do |step|
            step.write_context(:foo, 42)
            observed[:read_context_foo] = step.read_context(:foo)
            observed[:context_foo] = step.context[:foo]
            observed[:read_context_original] = step.read_context(:topic)
          end
        end
      end

      klass.new(context: { topic: "testing" }).run!

      expect(observed[:read_context_foo]).to eq(42)
      expect(observed[:context_foo]).to be_nil
      expect(observed[:read_context_original]).to eq("testing")
    end

    it "provides isolated context snapshots" do
      observed_context = nil

      klass = with_stubbed_class("SpecIsolatedContextWorkflow", workflow_class) do
        initial_state :idle
        state :done

        transition :check, from: :idle, to: :done do
          compute do |step|
            observed_context = step.context
            observed_context[:topic] = "mutated"
          end
        end
      end

      workflow = klass.new(context: { topic: "original" })
      result = workflow.run!

      expect(observed_context[:topic]).to eq("mutated")
      expect(result.context[:topic]).to eq("original")
    end

    it "clears a previously written outcome when a later step fails" do
      klass = with_stubbed_class("SpecOutcomeClearedOnFailureWorkflow", workflow_class) do
        initial_state :idle
        state :prepared
        state :done
        state :failed

        transition :prepare, from: :idle, to: :prepared do
          run do |step|
            step.write_outcome(kind: :artifact_ready, payload: { title: "Prepared artifact" })
          end
          on_success :explode
        end

        transition :explode, from: :prepared, to: :done do
          compute { |_step| raise "boom" }
          on_failure :fail
        end
      end

      result = klass.new.run!

      expect(result.state).to eq(:failed)
      expect(result.outcome).to be_nil
      expect(result.outcome_kind).to be_nil
      expect(result.outcome_payload).to be_nil
    end
  end

  # ---------------------------------------------------------------------------
  # Persistence
  # ---------------------------------------------------------------------------

  describe "persistence" do
    it "context written by run survives to_state/from_state round-trip" do
      manager = with_stubbed_class("SpecDetPersistContext", context_class) do
        persist :artifact
      end

      klass = with_stubbed_class("SpecDetPersistWorkflow", workflow_class) do
        initial_state :idle
        state :normalized
        state :done
        context_manager manager

        transition :normalize, from: :idle, to: :normalized do
          run { |step| step.write_context(:artifact, { title: "Test" }) }
        end

        transition :finish, from: :normalized, to: :done do
          compute { |_step| }
        end
      end

      workflow = klass.new
      workflow.advance!

      state = workflow.to_state
      restored = klass.from_state(state)

      expect(restored.to_state[:context]).to eq(artifact: { title: "Test" })
      expect(restored.state).to eq(:normalized)
    end

    it "route_to target survives persistence via next_transition_name" do
      klass = with_stubbed_class("SpecDetPersistRouteWorkflow", workflow_class) do
        initial_state :idle
        state :verified
        state :done

        transition :verify, from: :idle, to: :verified do
          compute { |step| step.route_to(:finish) }
        end

        transition :finish, from: :verified, to: :done do
          compute { |_step| }
        end
      end

      workflow = klass.new
      workflow.advance!

      state_hash = workflow.to_state
      expect(state_hash[:next_transition_name]).to eq(:finish)

      restored = klass.from_state(state_hash)
      result = restored.run!

      expect(result.state).to eq(:done)
      transitions = result.steps.map { |s| s[:transition] }
      expect(transitions).to eq([:finish])
    end

    it "string route_to target survives persistence and JSON round-trip exactly" do
      klass = with_stubbed_class("SpecDetPersistStringRouteWorkflow", workflow_class) do
        initial_state :idle
        state :verified
        state :done

        transition :verify, from: :idle, to: :verified do
          compute(routes: ["finish"]) { |step| step.route_to("finish") }
        end

        transition "finish", from: :verified, to: :done do
          compute { |step| step.read_context(:noop) }
        end
      end

      workflow = klass.new
      workflow.advance!

      restored = klass.from_state(workflow.to_state)
      restored_after_json = klass.from_state(JSON.parse(JSON.generate(workflow.to_state)))

      expect(restored.to_state[:next_transition_name]).to eq("finish")
      expect(restored.run!.steps.map { |step| step[:transition] }).to eq(["finish"])
      expect(restored_after_json.to_state[:next_transition_name]).to eq("finish")
      expect(restored_after_json.run!.steps.map { |step| step[:transition] }).to eq(["finish"])
    end

    it "survives a JSON round-trip" do
      manager = with_stubbed_class("SpecDetJsonContext", context_class) do
        persist :data
      end

      klass = with_stubbed_class("SpecDetJsonWorkflow", workflow_class) do
        initial_state :idle
        state :done
        context_manager manager

        transition :normalize, from: :idle, to: :done do
          run { |step| step.write_context(:data, { key: "value" }) }
        end
      end

      workflow = klass.new
      workflow.run!

      parsed = JSON.parse(JSON.generate(workflow.to_state))
      restored = klass.from_state(parsed)

      # Nested keys come back as Symbols, exactly as the live run held them.
      expect(workflow.to_state[:context]).to eq(data: { key: "value" })
      expect(restored.to_state[:context]).to eq(data: { key: "value" })
    end

    it "holds Symbol keys at every depth live and after a JSON restore" do
      manager = with_stubbed_class("SpecDetDeepKeysContext", context_class) do
        persist :input, :data
      end

      klass = with_stubbed_class("SpecDetDeepKeysWorkflow", workflow_class) do
        initial_state :idle
        state :done
        context_manager manager

        transition :normalize, from: :idle, to: :done do
          run do |step|
            step.write_context(:data, { "fields" => { "title" => "Engineer" }, "items" => [{ "id" => 1 }] })
          end
        end
      end

      workflow = klass.new(context: { "input" => { "nested" => { "deep" => true } } })
      workflow.run!
      live = workflow.to_state[:context]
      restored = klass.from_state(JSON.parse(JSON.generate(workflow.to_state))).to_state[:context]

      expected = {
        input: { nested: { deep: true } },
        data: { fields: { title: "Engineer" }, items: [{ id: 1 }] }
      }
      expect(live).to eq(expected)
      expect(restored).to eq(expected)
      expect(restored.dig(:data, :fields, :title)).to eq("Engineer")
    end

    it "outcome written by run survives to_state/from_state round-trip" do
      klass = with_stubbed_class("SpecDetPersistOutcomeWorkflow", workflow_class) do
        initial_state :idle
        state :prepared
        state :done

        transition :prepare, from: :idle, to: :prepared do
          run do |step|
            step.write_outcome(kind: :artifact_ready, payload: { title: "Test artifact", insights: [{ text: "Insight" }] })
            step.route_to(:finish)
          end
        end

        transition :finish, from: :prepared, to: :done do
          compute { |_step| }
        end
      end

      workflow = klass.new
      workflow.advance!

      restored = klass.from_state(workflow.to_state)

      expect(restored.to_state[:outcome]).to eq(
        kind: :artifact_ready,
        payload: { title: "Test artifact", insights: [{ text: "Insight" }] }
      )
      expect(restored.to_state[:next_transition_name]).to eq(:finish)
    end

    it "outcome survives a JSON round-trip" do
      klass = with_stubbed_class("SpecDetJsonOutcomeWorkflow", workflow_class) do
        initial_state :idle
        state :done

        transition :prepare, from: :idle, to: :done do
          run do |step|
            step.write_outcome(kind: :artifact_ready, payload: { title: "Test artifact", insights: [{ text: "Insight" }] })
          end
        end
      end

      workflow = klass.new
      workflow.run!

      restored = klass.from_state(JSON.parse(JSON.generate(workflow.to_state)))

      expect(restored.to_state[:outcome]).to eq(
        kind: :artifact_ready,
        payload: { title: "Test artifact", insights: [{ text: "Insight" }] }
      )
    end

    it "reads a String-keyed outcome identically live and after a JSON restore" do
      klass = with_stubbed_class("SpecDetStringKeyedOutcomeWorkflow", workflow_class) do
        initial_state :idle
        state :done

        transition :prepare, from: :idle, to: :done do
          run do |step|
            step.write_outcome(
              kind: :artifact_ready,
              payload: { "title" => "Test artifact", "insights" => [{ "text" => "Insight" }] }
            )
          end
        end
      end

      workflow = klass.new
      live = workflow.run!
      restored = klass.from_state(JSON.parse(JSON.generate(workflow.to_state))).run!

      expect(live.outcome_payload).to eq(title: "Test artifact", insights: [{ text: "Insight" }])
      expect(restored.outcome_payload).to eq(live.outcome_payload)
      expect(restored.outcome).to eq(live.outcome)
    end
  end

  # ---------------------------------------------------------------------------
  # Trace
  # ---------------------------------------------------------------------------

  describe "trace" do
    let(:trace_adapter) { Smith::Trace::Memory.new }

    before do
      Smith.config.trace_adapter = trace_adapter
      Smith.config.trace_content = true
    end

    after do
      Smith.config.trace_adapter = nil
      Smith.config.trace_content = false
      Smith::Trace.reset!
    end

    it "emits started, success, and transition traces on successful compute" do
      klass = with_stubbed_class("SpecTraceSuccessWorkflow", workflow_class) do
        initial_state :idle
        state :done

        transition :check, from: :idle, to: :done do
          compute { |_step| }
        end
      end

      klass.new.run!

      det_traces = trace_adapter.traces.select { |t| t[:type] == :deterministic_step }
      transition_traces = trace_adapter.traces.select { |t| t[:type] == :transition }

      expect(det_traces.length).to eq(2)
      expect(det_traces[0][:data][:outcome]).to eq(:started)
      expect(det_traces[0][:data][:kind]).to eq(:compute)
      expect(det_traces[1][:data][:outcome]).to eq(:success)
      expect(det_traces.map { |t| t[:data] }).to all(satisfy { |data| !data.key?(:result) })

      expect(transition_traces.length).to eq(1)
      expect(transition_traces[0][:data][:transition]).to eq(:check)
    end

    it "emits routed trace when route_to is called" do
      klass = with_stubbed_class("SpecTraceRoutedWorkflow", workflow_class) do
        initial_state :idle
        state :verified
        state :done

        transition :verify, from: :idle, to: :verified do
          compute { |step| step.route_to(:finish) }
        end

        transition :finish, from: :verified, to: :done do
          compute { |_step| }
        end
      end

      klass.new.run!

      det_traces = trace_adapter.traces.select { |t| t[:type] == :deterministic_step }
      routed = det_traces.find { |t| t[:data][:outcome] == :routed }

      expect(routed).not_to be_nil
      expect(routed[:data][:routed_to]).to eq(:finish)
    end

    it "emits outcome kind when write_outcome is called" do
      klass = with_stubbed_class("SpecTraceOutcomeWorkflow", workflow_class) do
        initial_state :idle
        state :done

        transition :prepare, from: :idle, to: :done do
          run do |step|
            step.write_outcome(kind: :artifact_ready, payload: { title: "Test artifact" })
          end
        end
      end

      klass.new.run!

      det_traces = trace_adapter.traces.select { |t| t[:type] == :deterministic_step }
      success = det_traces.find { |t| t[:data][:outcome] == :success }

      expect(success).not_to be_nil
      expect(success[:data][:outcome_kind]).to eq(:artifact_ready)
    end

    it "emits failed trace on step.fail!" do
      klass = with_stubbed_class("SpecTraceFailedWorkflow", workflow_class) do
        initial_state :idle
        state :done
        state :failed

        transition :verify, from: :idle, to: :done do
          compute { |step| step.fail!("bad research") }
          on_failure :fail
        end
      end

      klass.new.run!

      det_traces = trace_adapter.traces.select { |t| t[:type] == :deterministic_step }
      failed = det_traces.find { |t| t[:data][:outcome] == :failed }

      expect(failed).not_to be_nil
      expect(failed[:data]).to include(error_class: "Smith::DeterministicStepFailure",
                                       error_family: "deterministic_step_failure")
      expect(failed[:data]).not_to have_key(:error)
      expect(failed[:data].values.map(&:to_s)).not_to include(a_string_including("bad research"))
    end
  end

  # ---------------------------------------------------------------------------
  # Guardrails — constrained surface
  # ---------------------------------------------------------------------------

  describe "guardrails" do
    def deterministic_transition(name: :check, from: :idle, routes: nil)
      Struct.new(:name, :from, :deterministic_routes).new(name, from, routes)
    end

    it "keeps the direct constructor compatible with transition_name callers" do
      step = Smith::Workflow::DeterministicStep.new(
        context: {}, session_messages: [], tool_results: [], state: :idle, transition_name: :check
      )

      expect(step.transition_name).to eq(:check)
      expect(step.current_state).to eq(:idle)
    end

    it "does not expose mutable deterministic route metadata" do
      mutable_route = +"finish"
      step = Smith::Workflow::DeterministicStep.new(
        context: {}, session_messages: [], tool_results: [], state: :idle,
        transition: deterministic_transition(routes: [mutable_route])
      )

      expect(step.allowed_routes).to be_frozen
      expect(step.allowed_routes.first).to be_frozen

      mutable_route.replace("mutated")

      expect(step.allowed_routes.first).to eq("finish")
    end

    it "does not expose a workflow instance on the step object" do
      step = Smith::Workflow::DeterministicStep.new(
        context: {}, session_messages: [], tool_results: [], state: :idle, transition: deterministic_transition
      )

      expect(step).not_to respond_to(:workflow)
      expect(step).not_to respond_to(:advance!)
      expect(step).not_to respond_to(:run!)
      expect(step).not_to respond_to(:persist!)
      expect(step).not_to respond_to(:to_state)
    end

    it "does not expose persistence adapter, registry, or logger" do
      step = Smith::Workflow::DeterministicStep.new(
        context: {}, session_messages: [], tool_results: [], state: :idle, transition: deterministic_transition
      )

      expect(step).not_to respond_to(:persistence_adapter)
      expect(step).not_to respond_to(:registry)
      expect(step).not_to respond_to(:logger)
      expect(step).not_to respond_to(:ledger)
    end

    it "enforces explicit context writes instead of arbitrary mutation" do
      step = Smith::Workflow::DeterministicStep.new(
        context: { topic: "original" }, session_messages: [], tool_results: [],
        state: :idle, transition: deterministic_transition
      )

      step.write_context(:result, "computed")

      expect(step.context_writes).to eq(result: "computed")
      expect(step.context[:topic]).to eq("original")
    end
  end

  # ---------------------------------------------------------------------------
  # Integration — mixed workflow
  # ---------------------------------------------------------------------------

  describe "integration" do
    it "runs a full workflow mixing agent and deterministic steps" do
      agent = with_stubbed_class("SpecIntegrationAgent", agent_class) do
        register_as :spec_integration_agent
        model "gpt-5-mini"
      end

      fake_chat = Object.new
      fake_chat.define_singleton_method(:add_message) { |_| nil }
      fake_chat.define_singleton_method(:complete) do
        Struct.new(:content, :input_tokens, :output_tokens).new("research result", 10, 20)
      end

      allow(agent).to receive(:chat).and_return(fake_chat)

      klass = with_stubbed_class("SpecIntegrationWorkflow", workflow_class) do
        initial_state :idle
        state :gathered
        state :verified
        state :normalized
        state :done

        transition :research, from: :idle, to: :gathered do
          execute :spec_integration_agent
        end

        transition :verify, from: :gathered, to: :verified do
          compute do |step|
            if step.last_output.nil?
              step.fail!("no research output")
            else
              step.write_context(:verified, true)
            end
          end
        end

        transition :normalize, from: :verified, to: :normalized do
          run do |step|
            step.write_context(:normalized_output, step.last_output&.upcase)
          end
        end

        transition :finish, from: :normalized, to: :done do
          compute { |_step| }
        end
      end

      workflow = klass.new
      result = workflow.run!

      expect(result.state).to eq(:done)
      expect(result.steps.length).to eq(4)
      expect(result.context[:verified]).to be true
      expect(result.context[:normalized_output]).to eq("RESEARCH RESULT")

      transitions = result.steps.map { |s| s[:transition] }
      expect(transitions).to eq(%i[research verify normalize finish])
    end
  end

  # ---------------------------------------------------------------------------
  # Fail-closed routing and writes
  # ---------------------------------------------------------------------------

  describe "declared routes must be taken" do
    def routed_workflow(name, fallthrough: nil, on_success: nil)
      route_options = { routes: [:chosen] }
      route_options[:fallthrough] = fallthrough unless fallthrough.nil?
      with_stubbed_class(name, workflow_class) do
        initial_state :idle
        state :failed

        transition :decide, from: :idle, to: :decided do
          compute(**route_options) { |step| step.write_context(:seen, true) }
          on_success on_success if on_success
          on_failure :fail
        end

        transition :default_path, from: :decided, to: :defaulted
        transition :chosen, from: :decided, to: :chosen_done
      end
    end

    it "fails a step that declares routes but never routes, keeping none of its writes" do
      result = routed_workflow("SpecUnroutedWorkflow").new.run!

      expect(result.state).to eq(:failed)
      error = result.steps.first[:error]
      expect(error).to be_a(Smith::UnroutedDeterministicStep)
      expect(error).to be_a(Smith::WorkflowError)
      expect(error.transition).to eq(:decide)
      expect(error.routes).to eq([:chosen])
      expect(result.context).not_to have_key(:seen)
    end

    it "takes on_success when the step declares it and does not route" do
      result = routed_workflow("SpecUnroutedOnSuccessWorkflow", on_success: :chosen).new.run!

      expect(result.state).to eq(:chosen_done)
    end

    it "takes the first transition from the target state with fallthrough: true" do
      result = routed_workflow("SpecFallthroughWorkflow", fallthrough: true).new.run!

      expect(result.state).to eq(:defaulted)
      expect(result.context).to include(seen: true)
    end

    it "rejects fallthrough: without routes: and non-boolean values at definition time" do
      expect do
        with_stubbed_class("SpecFallthroughNoRoutesWorkflow", workflow_class) do
          initial_state :idle
          transition(:decide, from: :idle, to: :done) { compute(fallthrough: true) { |_step| nil } }
        end
      end.to raise_error(Smith::WorkflowError, /fallthrough: requires routes:/)

      expect do
        with_stubbed_class("SpecFallthroughTruthyWorkflow", workflow_class) do
          initial_state :idle
          transition(:decide, from: :idle, to: :done) { compute(routes: [:x], fallthrough: "yes") { |_step| nil } }
        end
      end.to raise_error(Smith::WorkflowError, /fallthrough must be true or false/)
    end

    it "shows graph inspection only the successors the step can actually take" do
      strict = routed_workflow("SpecRoutesGraphStrictWorkflow")
      loose = routed_workflow("SpecRoutesGraphLooseWorkflow", fallthrough: true)

      expect(strict.graph.reachable_transitions.map(&:name)).to contain_exactly(:decide, :chosen)
      expect(loose.graph.reachable_transitions.map(&:name)).to contain_exactly(:decide, :chosen, :default_path)

      snapshot = ->(klass, name) { klass.graph.transition_snapshots.find { _1.name == name }.to_h }
      expect(snapshot.call(strict, :decide)).to include(deterministic_fallthrough: false)
      expect(snapshot.call(loose, :decide)).to include(deterministic_fallthrough: true)
      expect(snapshot.call(strict, :chosen)).not_to have_key(:deterministic_fallthrough)
    end
  end

  describe "writes stay within an explicit persist list" do
    def writing_workflow(name, manager)
      with_stubbed_class(name, workflow_class) do
        initial_state :idle
        state :failed
        context_manager manager if manager

        transition :write, from: :idle, to: :done do
          compute do |step|
            step.write_context(:declared, 1)
            step.write_context(:undeclared, 2)
          end
          on_failure :fail
        end
      end
    end

    it "fails a write to a key the persist list does not declare" do
      manager = with_stubbed_class("SpecExplicitPersistContext", context_class) { persist :declared }
      result = writing_workflow("SpecUndeclaredWriteWorkflow", manager).new.run!

      expect(result.state).to eq(:failed)
      error = result.steps.first[:error]
      expect(error).to be_a(Smith::UndeclaredContextKey)
      expect(error.key).to eq(:undeclared)
      expect(error.persisted_keys).to eq([:declared])
      expect(result.context).not_to have_key(:declared)
    end

    it "allows any key under persist :auto or with no persist declaration" do
      auto = with_stubbed_class("SpecAutoPersistWriteContext", context_class) { persist :auto }

      expect(writing_workflow("SpecAutoWriteWorkflow", auto).new.run!.context).to include(declared: 1, undeclared: 2)
      expect(writing_workflow("SpecUnmanagedWriteWorkflow", nil).new.run!.context)
        .to include(declared: 1, undeclared: 2)
    end
  end
end
