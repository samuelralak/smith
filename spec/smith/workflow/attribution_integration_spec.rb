# frozen_string_literal: true

require "json"

RSpec.describe "Smith::Workflow ambient attribution" do
  let(:agent_class) { require_const("Smith::Agent") }
  let(:workflow_class) { require_const("Smith::Workflow") }
  let(:memory_trace_class) { require_const("Smith::Trace::Memory") }

  let(:adapter) do
    Class.new do
      def initialize
        @store = {}
      end

      def store(key, payload)
        @store[key] = payload
      end

      def fetch(key)
        @store[key]
      end

      def delete(key)
        @store.delete(key)
      end
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

  it "stamps the persistence key as execution_key on step traces of a persisted run" do
    klass = with_stubbed_class("SpecAttributionPersistedWorkflow", workflow_class) do
      initial_state :idle
      state :done

      transition :finish, from: :idle, to: :done
    end
    trace_adapter = memory_trace_class.new

    with_trace_adapter(trace_adapter) do
      klass.new.run_persisted!("wf:attribution-1", adapter:)
    end

    transition_traces = trace_adapter.traces.select { |t| t[:type] == :transition }
    expect(transition_traces).to eq([
                                      { type: :transition,
                                        data: { execution_key: "wf:attribution-1",
                                                transition: :finish, from: :idle, to: :done,
                                                workflow: "SpecAttributionPersistedWorkflow" } }
                                    ])
  end

  it "threads a host-seeded execution_key through a non-persisted run" do
    klass = with_stubbed_class("SpecAttributionSeededWorkflow", workflow_class) do
      initial_state :idle
      state :done

      transition :finish, from: :idle, to: :done
    end
    trace_adapter = memory_trace_class.new

    with_trace_adapter(trace_adapter) do
      Smith::Attribution.with(execution_key: "host-run-77") { klass.new.run! }
    end

    transition_traces = trace_adapter.traces.select { |t| t[:type] == :transition }
    expect(transition_traces.first[:data]).to eq(
      execution_key: "host-run-77", transition: :finish, from: :idle, to: :done,
      workflow: "SpecAttributionSeededWorkflow"
    )
  end

  it "carries step attribution into fan-out branch threads and overlays the branch key" do
    observed = Queue.new
    with_stubbed_class("SpecAttributionFanoutFirstAgent", agent_class) do
      register_as :spec_attribution_fanout_first_agent
      model "test-model"
    end
    with_stubbed_class("SpecAttributionFanoutSecondAgent", agent_class) do
      register_as :spec_attribution_fanout_second_agent
      model "test-model"
    end
    workflow = with_stubbed_class("SpecAttributionFanoutWorkflow", workflow_class) do
      initial_state :idle
      state :done

      transition :review, from: :idle, to: :done do
        fan_out branches: {
          first: :spec_attribution_fanout_first_agent,
          second: :spec_attribution_fanout_second_agent
        }
      end
    end.new
    workflow.define_singleton_method(:invoke_agent) do |_agent, _prepared_input|
      observed << Smith::Attribution.current
      "done"
    end

    workflow.run!

    contexts = 2.times.map { observed.pop }
    expect(contexts.map(&:branch_key)).to contain_exactly(:first, :second)
    expect(contexts.map(&:transition)).to all(eq(:review))
    expect(Smith::Attribution.current).to be_nil
  end

  it "scopes optimizer generator and evaluator calls to their round" do
    rounds = []
    generator = with_stubbed_class("SpecAttributionOptGen", agent_class) do
      register_as :spec_attribution_opt_gen
      model "gpt-5-mini"
    end
    evaluator = with_stubbed_class("SpecAttributionOptEval", agent_class) do
      register_as :spec_attribution_opt_eval
      model "gpt-5-mini"
    end
    stub_observing_agent(generator, "candidate", rounds)
    stub_observing_agent(evaluator, [
                           { accept: false, converged: false, feedback: "again", score: 0.1 },
                           { accept: true, feedback: nil, score: 0.9 }
                         ], rounds)
    schema = Class.new

    workflow = with_stubbed_class("SpecAttributionOptWorkflow", workflow_class) do
      initial_state :idle
      state :done

      transition :translate, from: :idle, to: :done do
        optimize generator: :spec_attribution_opt_gen, evaluator: :spec_attribution_opt_eval,
                 max_rounds: 3, evaluator_schema: schema
      end
    end.new

    result = workflow.run!

    expect(result.state).to eq(:done)
    # Round 0: generator + evaluator (rejected); round 1: generator +
    # evaluator (accepted). Every call sees its own round, never another's.
    expect(rounds).to eq([0, 0, 1, 1])
    expect(Smith::Attribution.current).to be_nil
  end

  it "labels child-graph facts with the child workflow under the shared root identity" do
    child = with_stubbed_class("SpecAttributionChildWorkflow", workflow_class) do
      initial_state :idle
      state :done

      transition :inner, from: :idle, to: :done
    end
    parent = with_stubbed_class("SpecAttributionParentWorkflow", workflow_class) do
      initial_state :idle
      state :done

      transition :outer, from: :idle, to: :done do
        workflow child
      end
    end
    trace_adapter = memory_trace_class.new

    with_trace_adapter(trace_adapter) do
      parent.new.run_persisted!("wf:nested-attribution", adapter:)
    end

    transitions = trace_adapter.traces.select { |t| t[:type] == :transition }
    labels = transitions.to_h { |t| [t[:data][:transition], t[:data][:workflow]] }
    expect(labels).to eq(
      inner: "SpecAttributionChildWorkflow",
      outer: "SpecAttributionParentWorkflow"
    )
    # Both graphs share the one root execution identity.
    expect(transitions.map { |t| t[:data][:execution_key] }.uniq).to eq(["wf:nested-attribution"])
  end

  # A transition declared without `from` (a routed :fail is the common case)
  # must not inherit the enclosing step's `from` through the nil-ignoring
  # merge: per-step attribution facts are replaced verbatim, nil included.
  it "does not inherit the parent's from into a child's from-less step" do
    raising_agent = with_stubbed_class("SpecFromNilRaisingAgent", agent_class) do
      register_as :spec_from_nil_raising_agent
      model "test-model"
    end
    allow(raising_agent).to receive(:chat).and_raise(StandardError, "boom")
    rescue_agent = with_stubbed_class("SpecFromNilRescueAgent", agent_class) do
      register_as :spec_from_nil_rescue_agent
      model "test-model"
    end
    stub_chat_for(rescue_agent)
    child = with_stubbed_class("SpecFromNilChildWorkflow", workflow_class) do
      initial_state :idle
      state :running
      state :failed

      transition :inner, from: :idle, to: :running do
        execute :spec_from_nil_raising_agent
        on_failure :fail
      end
      transition :fail, from: nil, to: :failed do
        execute :spec_from_nil_rescue_agent
      end
    end
    parent = with_stubbed_class("SpecFromNilParentWorkflow", workflow_class) do
      initial_state :outer_idle
      state :outer_done

      transition :outer, from: :outer_idle, to: :outer_done do
        workflow child
      end
    end
    trace_adapter = memory_trace_class.new

    with_trace_adapter(trace_adapter) do
      # The child's routed failure surfaces to the parent step as a nested
      # workflow failure; the child's traces are recorded before that.
      expect { parent.new.run! }.to raise_error(Smith::WorkflowError, /nested workflow failed/)
    end

    fail_trace = trace_adapter.traces.find { |t| t[:type] == :transition && t[:data][:transition] == :fail }
    expect(fail_trace).not_to be_nil
    # Explicitly nil, never the parent step's :outer_idle.
    expect(fail_trace[:data]).to include(from: nil, workflow: "SpecFromNilChildWorkflow")
    # The discriminating observable is a trace WITHOUT an explicit from key
    # (transition traces always carry one, so caller data would mask an
    # ambient leak): the rescue agent's provider_call reads pure ambient,
    # where an inherited parent `from` would surface as :outer_idle.
    provider_trace = trace_adapter.traces.find do |t|
      t[:type] == :provider_call && t[:data][:transition] == :fail
    end
    expect(provider_trace).not_to be_nil
    expect(provider_trace[:data]).not_to have_key(:from)
    expect(provider_trace[:data][:workflow]).to eq("SpecFromNilChildWorkflow")
  end

  def stub_chat_for(klass)
    allow(klass).to receive(:chat) do
      chat = Object.new
      chat.define_singleton_method(:add_message) { |_msg| nil }
      chat.define_singleton_method(:complete) do
        Struct.new(:content, :input_tokens, :output_tokens).new("recovered", 5, 3)
      end
      chat
    end
  end

  def stub_observing_agent(klass, results, rounds)
    sequence = results.is_a?(Array) ? results : [results]
    call_index = Concurrent::AtomicFixnum.new(-1)
    allow(klass).to receive(:chat) do
      rounds << Smith::Attribution.current&.round
      stub_chat(sequence[call_index.increment] || sequence.last)
    end
  end

  def stub_chat(result)
    chat = Object.new
    chat.define_singleton_method(:add_message) { |_msg| nil }
    chat.define_singleton_method(:with_schema) { |_s| self }
    chat.define_singleton_method(:complete) do
      Struct.new(:content, :input_tokens, :output_tokens).new(result, 5, 3)
    end
    chat
  end
end
