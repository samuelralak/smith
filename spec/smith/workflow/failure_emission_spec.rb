# frozen_string_literal: true

RSpec.describe "Smith failure-path emission and cost traces" do
  let(:agent_class) { require_const("Smith::Agent") }
  let(:workflow_class) { require_const("Smith::Workflow") }
  let(:memory_trace_class) { require_const("Smith::Trace::Memory") }

  let(:adapter) do
    Class.new do
      def initialize = @store = {}
      def store(key, payload) = @store[key] = payload
      def fetch(key) = @store[key]
      def delete(key) = @store.delete(key)
    end.new
  end

  def with_trace_adapter(trace_adapter)
    original_adapter = Smith.config.trace_adapter

    Smith.configure { |config| config.trace_adapter = trace_adapter }
    Smith::Trace.reset!
    yield
  ensure
    Smith.configure { |config| config.trace_adapter = original_adapter }
    Smith::Trace.reset!
  end

  def with_setting(name, value)
    original = Smith.config.public_send(name)

    Smith.configure { |config| config.public_send("#{name}=", value) }
    yield
  ensure
    Smith.configure { |config| config.public_send("#{name}=", original) }
  end

  def failing_workflow(name)
    workflow = with_stubbed_class(name, workflow_class) do
      initial_state :idle
      state :running
      state :failed

      transition :start, from: :idle, to: :running do
        on_failure :fail
      end
    end.new
    workflow.define_singleton_method(:execute_transition_body) do |_transition, **|
      raise Smith::DeadlineExceeded, "too slow"
    end
    workflow
  end

  it "records a failed transition trace with bounded classification and no raw message" do
    trace_adapter = memory_trace_class.new

    with_trace_adapter(trace_adapter) do
      result = failing_workflow("SpecFailureTraceWorkflow").run!
      expect(result.state).to eq(:failed)
    end

    failed_traces = trace_adapter.traces.select { |t| t[:type] == :transition && t[:data][:outcome] == :failed }
    expect(failed_traces.length).to eq(1)
    data = failed_traces.first[:data]
    expect(data[:transition]).to eq(:start)
    expect(data[:error_class]).to eq("Smith::DeadlineExceeded")
    expect(data[:error_family]).to eq("deadline_exceeded")
    expect(data.values.join).not_to include("too slow")
    # The step failed, so no success transition trace exists for it.
    expect(trace_adapter.traces.count { |t| t[:type] == :transition && !t[:data].key?(:outcome) }).to eq(0)
  end

  it "stamps the persistence key on StepFailed during a persisted run" do
    observed = []
    subscription = Smith::Events.on(Smith::Events::StepFailed) { |event| observed << event }

    result = failing_workflow("SpecFailureIdentityWorkflow").run_persisted!("wf:failure-id", adapter:)
    subscription.cancel

    expect(result.state).to eq(:failed)
    expect(observed.length).to eq(1)
    expect(observed.first.execution_id).to eq("wf:failure-id")
    expect(observed.first.error_family).to eq("deadline_exceeded")
  end

  it "emits StepFailed from the unresolved-transition path when a :fail transition exists" do
    observed = []
    workflow = with_stubbed_class("SpecUnresolvedFailureWorkflow", workflow_class) do
      initial_state :idle
      state :running
      state :failed

      transition :start, from: :idle, to: :running
      transition :fail, from: :running, to: :failed
    end.new
    subscription = Smith::Events.on(Smith::Events::StepFailed) { |event| observed << event }

    workflow.advance!
    workflow.instance_variable_set(:@next_transition_name, :missing_step)
    workflow.advance!
    subscription.cancel

    expect(workflow.state).to eq(:failed)
    expect(observed.length).to eq(1)
    expect(observed.first.transition).to eq(:missing_step)
    expect(observed.first.error_class).to eq("Smith::UnresolvedTransitionError")
  end

  # A step body surfacing Smith's own UnresolvedTransitionError is captured,
  # staged, and emitted by the step-failure path first; advance!'s rescue
  # must recognize the already-emitted error instead of emitting a second
  # StepFailed under the requested name (a transition that never executed).
  it "emits exactly one StepFailed when a step body raises UnresolvedTransitionError" do
    observed = []
    workflow = with_stubbed_class("SpecBodyUnresolvedWorkflow", workflow_class) do
      initial_state :idle
      state :running
      state :failed

      transition :start, from: :idle, to: :running
      transition :fail, from: :idle, to: :failed
    end.new
    workflow.define_singleton_method(:execute_transition_body) do |_transition, **|
      raise Smith::UnresolvedTransitionError.new(:phantom_route, self.class, :idle)
    end
    subscription = Smith::Events.on(Smith::Events::StepFailed) { |event| observed << event }

    workflow.advance!
    subscription.cancel

    expect(workflow.state).to eq(:failed)
    expect(observed.length).to eq(1)
    # The real failing step's identity, never the phantom requested name.
    expect(observed.first.transition).to eq(:start)
  end

  # The unresolved handler runs outside any step context (advance! rescues
  # after the step unwound), so run identity must be seeded there explicitly.
  it "stamps the persistence key on unresolved-transition StepFailed in persisted runs" do
    observed = []
    klass = with_stubbed_class("SpecUnresolvedIdentityWorkflow", workflow_class) do
      initial_state :idle
      state :running
      state :failed

      transition :start, from: :idle, to: :running
      transition :fail, from: :running, to: :failed
    end
    workflow = klass.new
    workflow.persist!("wf:unresolved-id", adapter: adapter)
    subscription = Smith::Events.on(Smith::Events::StepFailed) { |event| observed << event }

    workflow.advance!
    workflow.instance_variable_set(:@next_transition_name, :missing_step)
    workflow.advance!
    subscription.cancel

    expect(observed.length).to eq(1)
    expect(observed.first.execution_id).to eq("wf:unresolved-id")
  end

  # Handlers must run interruptible: emission is staged in the failure
  # rescue (which executes under the step snapshot's interrupt mask) and
  # flushed after the mask closes. The torn-down tool context is the
  # deterministic observable for "outside the step region": before this
  # change, handlers saw the step's live collector.
  it "runs StepFailed handlers outside the step context region with seeded identity" do
    observed_collector = :unset
    observed_event = nil
    subscription = Smith::Events.on(Smith::Events::StepFailed) do |event|
      observed_collector = Smith::Tool.current_tool_result_collector
      observed_event = event
    end

    failing_workflow("SpecDeferredEmissionWorkflow").run_persisted!("wf:deferred-emit", adapter:)
    subscription.cancel

    expect(observed_collector).to be_nil
    expect(observed_event.execution_id).to eq("wf:deferred-emit")
    expect(observed_event.workflow).to eq("SpecDeferredEmissionWorkflow")
  end

  it "an emission failure never masks the original step error" do
    broken_bus = Class.new do
      def record(**) = raise "adapter exploded"
    end.new

    with_trace_adapter(broken_bus) do
      result = failing_workflow("SpecFailureIsolationWorkflow").run!
      expect(result.state).to eq(:failed)
      expect(result.failure_detail[:error]).to be_a(Smith::DeadlineExceeded)
    end
  end

  describe ":cost emission" do
    def priced_agent_workflow(name)
      stub_priced_agent(name)
      with_stubbed_class(name, workflow_class) do
        initial_state :idle
        state :done

        transition :finish, from: :idle, to: :done do
          execute :"#{name.downcase}_agent"
        end
      end.new
    end

    def stub_priced_agent(name)
      agent = with_stubbed_class("#{name}Agent", agent_class) do
        register_as :"#{name.downcase}_agent"
        model "test-model"
      end
      allow(agent).to receive(:chat) { priced_chat }
    end

    def priced_chat
      chat = Object.new
      chat.define_singleton_method(:add_message) { |_msg| nil }
      chat.define_singleton_method(:complete) do
        Struct.new(:content, :input_tokens, :output_tokens).new("ok", 100, 50)
      end
      chat
    end

    it "emits exactly one :cost trace per completed invocation once pricing is configured" do
      trace_adapter = memory_trace_class.new
      pricing = { "test-model" => { input_cost_per_token: 0.00001, output_cost_per_token: 0.00002 } }

      with_setting(:pricing, pricing) do
        with_trace_adapter(trace_adapter) do
          priced_agent_workflow("SpecCostEmissionWorkflow").run!
        end
      end

      cost_traces = trace_adapter.traces.select { |t| t[:type] == :cost }
      expect(cost_traces.length).to eq(1)
      expect(cost_traces.first[:data][:cost]).to be_within(1e-9).of((100 * 0.00001) + (50 * 0.00002))
      expect(cost_traces.first[:data][:model]).to eq("test-model")
    end

    it "emits no :cost trace when usage is unpriced" do
      trace_adapter = memory_trace_class.new

      with_trace_adapter(trace_adapter) do
        priced_agent_workflow("SpecUnpricedCostWorkflow").run!
      end

      expect(trace_adapter.traces.select { |t| t[:type] == :cost }).to be_empty
    end

    it "sums per-response costs under tiered pricing instead of pricing the aggregate" do
      tiered = { "tier-model" => { tiers: [
        { max_input_tokens: 100_000, input_cost_per_token: 1e-6, output_cost_per_token: 2e-6 },
        { max_input_tokens: nil, input_cost_per_token: 2e-6, output_cost_per_token: 4e-6 }
      ] } }
      usage = Struct.new(:input_tokens, :output_tokens)
      completion = Struct.new(:provider_usages, :usage_complete)
                         .new([usage.new(80_000, 10), usage.new(90_000, 10)], true)
      agent = with_stubbed_class("SpecTierCostAgent", agent_class) { register_as :spec_tier_cost_agent }
      workflow = with_stubbed_class("SpecTierCostWorkflow", workflow_class) do
        initial_state :idle
        state :done

        transition :finish, from: :idle, to: :done
      end.new
      reference = Smith::Agent::ModelReference.new(model_id: "tier-model", provider: nil)

      invocation_cost, fully_priced = with_setting(:pricing, tiered) do
        workflow.send(:record_completion_usage, agent, completion, :completed_attempt, reference)
      end

      # Each response sits below the first tier ceiling, so the truthful sum
      # prices both in tier one; pricing the 170k aggregate would resolve
      # tier two and roughly double the figure.
      per_response_sum = ((80_000 + 90_000) * 1e-6) + (20 * 2e-6)
      aggregate_mispriced = (170_000 * 2e-6) + (20 * 4e-6)
      expect(invocation_cost).to be_within(1e-12).of(per_response_sum)
      expect(invocation_cost).to be < aggregate_mispriced / 1.9
      expect(fully_priced).to be(true)
    end

    # Budget settlement reads agent_result.cost, so the settled figure must
    # be the same per-response sum the entries and the :cost trace carry.
    # Before this alignment, a tiered catalog whose aggregate missed every
    # tier settled the cost dimension at zero while the entries were priced.
    it "settles agent_result.cost from the per-response sum, never the aggregate" do
      tiered = { "tier-model" => { tiers: [
        { max_input_tokens: 100_000, input_cost_per_token: 1e-6, output_cost_per_token: 2e-6 },
        { max_input_tokens: 150_000, input_cost_per_token: 2e-6, output_cost_per_token: 4e-6 }
      ] } }
      usage = Struct.new(:input_tokens, :output_tokens)
      completion = Struct.new(:provider_usages, :usage_complete)
                         .new([usage.new(80_000, 10), usage.new(90_000, 10)], true)
      agent = with_stubbed_class("SpecBudgetCostAgent", agent_class) { register_as :spec_budget_cost_agent }
      workflow = with_stubbed_class("SpecBudgetCostWorkflow", workflow_class) do
        initial_state :idle
        state :done

        transition :finish, from: :idle, to: :done
      end.new
      reference = Smith::Agent::ModelReference.new(model_id: "tier-model", provider: nil)
      agent_result = Smith::Workflow::AgentResult.new(
        content: "ok", input_tokens: 170_000, output_tokens: 20, cost: nil,
        model_used: "tier-model", provider_used: nil
      )

      with_setting(:pricing, tiered) do
        workflow.send(:account_completion!, agent, completion, reference, agent_result, nil)
      end

      # The 170k aggregate misses every tier (nil cost); the truthful
      # settled figure is the priced per-response sum.
      per_response_sum = ((80_000 + 90_000) * 1e-6) + (20 * 2e-6)
      expect(agent_result.cost).to be_within(1e-12).of(per_response_sum)
    end

    it "emits no :cost trace when only part of the invocation could be priced" do
      trace_adapter = memory_trace_class.new
      # Tier one covers the first response only; the 5000-token response
      # misses every tier, so the invocation is partially priced.
      tiered = { "tier-model" => { tiers: [
        { max_input_tokens: 1_000, input_cost_per_token: 1e-6, output_cost_per_token: 2e-6 }
      ] } }
      usage = Struct.new(:input_tokens, :output_tokens)
      completion = Struct.new(:provider_usages, :usage_complete).new([usage.new(100, 10), usage.new(5_000, 10)], true)
      agent = with_stubbed_class("SpecPartialCostAgent", agent_class) { register_as :spec_partial_cost_agent }
      workflow = with_stubbed_class("SpecPartialCostWorkflow", workflow_class) do
        initial_state :idle
        state :done

        transition :finish, from: :idle, to: :done
      end.new
      reference = Smith::Agent::ModelReference.new(model_id: "tier-model", provider: nil)
      agent_result = Smith::Workflow::AgentResult.new(
        content: "ok", input_tokens: 5_100, output_tokens: 20, cost: nil,
        model_used: "tier-model", provider_used: nil
      )

      with_setting(:pricing, tiered) do
        with_trace_adapter(trace_adapter) do
          workflow.send(:account_completion!, agent, completion, reference, agent_result, nil)
        end
      end

      expect(trace_adapter.traces.select { |t| t[:type] == :cost }).to be_empty
      # The partial sum still settles the budget-facing cost: it is what
      # was verifiably billed.
      expect(agent_result.cost).to be_within(1e-12).of((100 * 1e-6) + (10 * 2e-6))
    end

    it "emits no :cost trace when a provider response was never metered" do
      trace_adapter = memory_trace_class.new
      pricing = { "test-model" => { input_cost_per_token: 1e-6, output_cost_per_token: 2e-6 } }
      usage = Struct.new(:input_tokens, :output_tokens)
      completion = Struct.new(:provider_usages, :usage_complete).new([usage.new(100, 10)], false)
      agent = with_stubbed_class("SpecUnmeteredCostAgent", agent_class) { register_as :spec_unmetered_cost_agent }
      workflow = with_stubbed_class("SpecUnmeteredCostWorkflow", workflow_class) do
        initial_state :idle
        state :done

        transition :finish, from: :idle, to: :done
      end.new
      reference = Smith::Agent::ModelReference.new(model_id: "test-model", provider: nil)
      agent_result = Smith::Workflow::AgentResult.new(
        content: "ok", input_tokens: nil, output_tokens: nil, cost: nil,
        model_used: "test-model", provider_used: nil
      )

      with_setting(:pricing, pricing) do
        with_trace_adapter(trace_adapter) do
          workflow.send(:account_completion!, agent, completion, reference, agent_result, nil)
        end
      end

      expect(trace_adapter.traces.select { |t| t[:type] == :cost }).to be_empty
    end

    it "suppresses :cost traces when trace_cost is false" do
      trace_adapter = memory_trace_class.new
      pricing = { "test-model" => { input_cost_per_token: 0.00001, output_cost_per_token: 0.00002 } }

      with_setting(:pricing, pricing) do
        with_setting(:trace_cost, false) do
          with_trace_adapter(trace_adapter) do
            priced_agent_workflow("SpecQuietCostWorkflow").run!
          end
        end
      end

      expect(trace_adapter.traces.select { |t| t[:type] == :cost }).to be_empty
    end
  end
end
