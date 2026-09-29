# frozen_string_literal: true

RSpec.describe "Smith::Workflow::EvaluatorOptimizer runtime behavior" do
  let(:agent_class) { require_const("Smith::Agent") }
  let(:workflow_class) { require_const("Smith::Workflow") }
  let(:workflow_error) { require_const("Smith::WorkflowError") }

  def stub_agent(klass, result)
    allow(klass).to receive(:chat) do
      chat = Object.new
      chat.define_singleton_method(:add_message) { |_msg| nil }
      chat.define_singleton_method(:with_schema) { |_s| self }
      chat.define_singleton_method(:complete) do
        Struct.new(:content, :input_tokens, :output_tokens).new(result, 5, 3)
      end
      chat
    end
  end

  def stub_agent_sequence(klass, results)
    call_idx = Concurrent::AtomicFixnum.new(-1)
    allow(klass).to receive(:chat) do
      idx = call_idx.increment
      result = results[idx] || results.last
      chat = Object.new
      chat.define_singleton_method(:add_message) { |_msg| nil }
      chat.define_singleton_method(:with_schema) { |_s| self }
      chat.define_singleton_method(:complete) do
        Struct.new(:content, :input_tokens, :output_tokens).new(result, 5, 3)
      end
      chat
    end
  end

  it "returns the accepted candidate as step output" do
    generator = with_stubbed_class("SpecOptGenAccept", agent_class) do
      register_as :spec_opt_gen_accept
      model "gpt-5-mini"
    end
    evaluator = with_stubbed_class("SpecOptEvalAccept", agent_class) do
      register_as :spec_opt_eval_accept
      model "gpt-5-mini"
    end

    stub_agent(generator, "great translation")
    stub_agent(evaluator, { accept: true, feedback: nil, score: 0.95 })

    schema = Class.new

    workflow = with_stubbed_class("SpecOptAcceptWorkflow", workflow_class) do
      initial_state :idle
      state :done
      state :failed

      transition :translate, from: :idle, to: :done do
        optimize generator: :spec_opt_gen_accept, evaluator: :spec_opt_eval_accept,
                 max_rounds: 3, evaluator_schema: schema
        on_failure :fail
      end
    end.new

    result = workflow.run!

    expect(result.state).to eq(:done)
    expect(result.output).to eq("great translation")
    expect(result.steps.length).to eq(1)
  end

  it "applies the evaluator schema without mutating a sealed agent class" do
    schema = Class.new
    observed_schemas = []
    chat_for = lambda do |content, schemas: nil|
      Object.new.tap do |chat|
        chat.define_singleton_method(:add_message) { |_message| nil }
        chat.define_singleton_method(:with_schema) do |value|
          schemas << value if schemas
          self
        end
        chat.define_singleton_method(:complete) do
          Struct.new(:content, :input_tokens, :output_tokens).new(content, 5, 3)
        end
      end
    end
    generator = with_stubbed_class("SpecOptSealedGenerator", agent_class) do
      register_as :spec_opt_sealed_generator
      model "gpt-5-mini"
      define_singleton_method(:chat) { |**| chat_for.call("candidate") }
    end
    evaluator = with_stubbed_class("SpecOptSealedEvaluator", agent_class) do
      register_as :spec_opt_sealed_evaluator
      model "gpt-5-mini"
      define_singleton_method(:chat) do |**|
        chat_for.call({ accept: true, feedback: nil }, schemas: observed_schemas)
      end
    end
    generator.freeze
    evaluator.freeze

    workflow = with_stubbed_class("SpecOptSealedWorkflow", workflow_class) do
      initial_state :idle
      state :done
      transition :improve, from: :idle, to: :done do
        optimize generator: :spec_opt_sealed_generator,
                 evaluator: :spec_opt_sealed_evaluator,
                 max_rounds: 2,
                 evaluator_schema: schema
      end
    end.new

    result = workflow.run!

    expect(result.state).to eq(:done)
    expect(result.output).to eq("candidate")
    expect(observed_schemas).to eq([schema])
    expect(evaluator.output_schema).to be_nil
  end

  it "fails the step after max_rounds without acceptance" do
    generator = with_stubbed_class("SpecOptGenExhaust", agent_class) do
      register_as :spec_opt_gen_exhaust
      model "gpt-5-mini"
    end
    evaluator = with_stubbed_class("SpecOptEvalExhaust", agent_class) do
      register_as :spec_opt_eval_exhaust
      model "gpt-5-mini"
    end

    stub_agent(generator, "draft")
    stub_agent(evaluator, { accept: false, feedback: "needs work", score: 0.5 })

    schema = Class.new

    workflow = with_stubbed_class("SpecOptExhaustWorkflow", workflow_class) do
      initial_state :idle
      state :done
      state :failed

      transition :translate, from: :idle, to: :done do
        optimize generator: :spec_opt_gen_exhaust, evaluator: :spec_opt_eval_exhaust,
                 max_rounds: 2, evaluator_schema: schema
        on_failure :fail
      end
    end.new

    result = workflow.run!

    expect(result.state).to eq(:failed)
    expect(result.steps.first[:error]).to be_a(workflow_error)
    expect(result.steps.first[:error].message).to include("exhausted 2 rounds")
  end

  it "fails the step when evaluator signals converged without acceptance" do
    generator = with_stubbed_class("SpecOptGenConverge", agent_class) do
      register_as :spec_opt_gen_converge
      model "gpt-5-mini"
    end
    evaluator = with_stubbed_class("SpecOptEvalConverge", agent_class) do
      register_as :spec_opt_eval_converge
      model "gpt-5-mini"
    end

    stub_agent(generator, "converged draft")
    stub_agent(evaluator, { accept: false, feedback: "minor", converged: true, score: 0.9 })

    schema = Class.new

    workflow = with_stubbed_class("SpecOptConvergeWorkflow", workflow_class) do
      initial_state :idle
      state :done
      state :failed

      transition :translate, from: :idle, to: :done do
        optimize generator: :spec_opt_gen_converge, evaluator: :spec_opt_eval_converge,
                 max_rounds: 5, evaluator_schema: schema
        on_failure :fail
      end
    end.new

    result = workflow.run!

    expect(result.state).to eq(:failed)
    expect(result.steps.first[:error]).to be_a(workflow_error)
    expect(result.steps.first[:error].message).to include("converged without acceptance")
  end

  it "fails when improvement falls below threshold" do
    generator = with_stubbed_class("SpecOptGenThreshold", agent_class) do
      register_as :spec_opt_gen_threshold
      model "gpt-5-mini"
    end
    evaluator = with_stubbed_class("SpecOptEvalThreshold", agent_class) do
      register_as :spec_opt_eval_threshold
      model "gpt-5-mini"
    end

    stub_agent(generator, "draft")
    stub_agent_sequence(evaluator, [
                          { accept: false, feedback: "try again", score: 0.7 },
                          { accept: false, feedback: "still not great", score: 0.71 }
                        ])

    schema = Class.new

    workflow = with_stubbed_class("SpecOptThresholdWorkflow", workflow_class) do
      initial_state :idle
      state :done
      state :failed

      transition :translate, from: :idle, to: :done do
        optimize generator: :spec_opt_gen_threshold, evaluator: :spec_opt_eval_threshold,
                 max_rounds: 5, evaluator_schema: schema, improvement_threshold: 0.05
        on_failure :fail
      end
    end.new

    result = workflow.run!

    expect(result.state).to eq(:failed)
    expect(result.steps.first[:error].message).to include("improvement below threshold")
  end

  it "fails on malformed evaluator output missing :accept" do
    generator = with_stubbed_class("SpecOptGenMalformed", agent_class) do
      register_as :spec_opt_gen_malformed
      model "gpt-5-mini"
    end
    evaluator = with_stubbed_class("SpecOptEvalMalformed", agent_class) do
      register_as :spec_opt_eval_malformed
      model "gpt-5-mini"
    end

    stub_agent(generator, "draft")
    stub_agent(evaluator, { feedback: "missing accept" })

    schema = Class.new

    workflow = with_stubbed_class("SpecOptMalformedWorkflow", workflow_class) do
      initial_state :idle
      state :done
      state :failed

      transition :translate, from: :idle, to: :done do
        optimize generator: :spec_opt_gen_malformed, evaluator: :spec_opt_eval_malformed,
                 max_rounds: 3, evaluator_schema: schema
        on_failure :fail
      end
    end.new

    result = workflow.run!

    expect(result.state).to eq(:failed)
    expect(result.steps.first[:error].message).to include("missing :accept")
  end

  it "fails loudly when the configured generator agent symbol is not registered" do
    evaluator = with_stubbed_class("SpecOptEvalRegisteredOnly", agent_class) do
      register_as :spec_opt_eval_registered_only
      model "gpt-5-mini"
    end

    stub_agent(evaluator, { accept: true, feedback: nil, score: 0.95 })

    schema = Class.new

    workflow = with_stubbed_class("SpecOptMissingGeneratorWorkflow", workflow_class) do
      initial_state :idle
      state :done
      state :failed

      transition :translate, from: :idle, to: :done do
        optimize generator: :missing_generator_agent, evaluator: :spec_opt_eval_registered_only,
                 max_rounds: 3, evaluator_schema: schema
        on_failure :fail
      end
    end.new

    result = workflow.run!

    expect(result.state).to eq(:failed)
    expect(result.steps.first[:error]).to be_a(workflow_error)
    expect(result.steps.first[:error].message).to include("unresolved generator :missing_generator_agent")
    expect(result.steps.first[:error].message).to include("transition :translate")
  end

  it "fails loudly when the configured evaluator agent symbol is not registered" do
    generator = with_stubbed_class("SpecOptGenRegisteredOnly", agent_class) do
      register_as :spec_opt_gen_registered_only
      model "gpt-5-mini"
    end

    stub_agent(generator, "draft")

    schema = Class.new

    workflow = with_stubbed_class("SpecOptMissingEvaluatorWorkflow", workflow_class) do
      initial_state :idle
      state :done
      state :failed

      transition :translate, from: :idle, to: :done do
        optimize generator: :spec_opt_gen_registered_only, evaluator: :missing_evaluator_agent,
                 max_rounds: 3, evaluator_schema: schema
        on_failure :fail
      end
    end.new

    result = workflow.run!

    expect(result.state).to eq(:failed)
    expect(result.steps.first[:error]).to be_a(workflow_error)
    expect(result.steps.first[:error].message).to include("unresolved evaluator :missing_evaluator_agent")
    expect(result.steps.first[:error].message).to include("transition :translate")
  end

  it "fails on non-boolean :accept" do
    generator = with_stubbed_class("SpecOptGenBadAccept", agent_class) do
      register_as :spec_opt_gen_bad_accept
      model "gpt-5-mini"
    end
    evaluator = with_stubbed_class("SpecOptEvalBadAccept", agent_class) do
      register_as :spec_opt_eval_bad_accept
      model "gpt-5-mini"
    end

    stub_agent(generator, "draft")
    stub_agent(evaluator, { accept: "yes", feedback: "ok" })

    schema = Class.new

    workflow = with_stubbed_class("SpecOptBadAcceptWorkflow", workflow_class) do
      initial_state :idle
      state :done
      state :failed

      transition :translate, from: :idle, to: :done do
        optimize generator: :spec_opt_gen_bad_accept, evaluator: :spec_opt_eval_bad_accept,
                 max_rounds: 3, evaluator_schema: schema
        on_failure :fail
      end
    end.new

    result = workflow.run!

    expect(result.state).to eq(:failed)
    expect(result.steps.first[:error].message).to include(":accept must be boolean")
  end

  it "fails when feedback is missing on rejection" do
    generator = with_stubbed_class("SpecOptGenNoFeedback", agent_class) do
      register_as :spec_opt_gen_no_feedback
      model "gpt-5-mini"
    end
    evaluator = with_stubbed_class("SpecOptEvalNoFeedback", agent_class) do
      register_as :spec_opt_eval_no_feedback
      model "gpt-5-mini"
    end

    stub_agent(generator, "draft")
    stub_agent(evaluator, { accept: false })

    schema = Class.new

    workflow = with_stubbed_class("SpecOptNoFeedbackWorkflow", workflow_class) do
      initial_state :idle
      state :done
      state :failed

      transition :translate, from: :idle, to: :done do
        optimize generator: :spec_opt_gen_no_feedback, evaluator: :spec_opt_eval_no_feedback,
                 max_rounds: 3, evaluator_schema: schema
        on_failure :fail
      end
    end.new

    result = workflow.run!

    expect(result.state).to eq(:failed)
    expect(result.steps.first[:error].message).to include("must provide :feedback")
  end

  it "rejects malformed optimize declaration with non-positive max_rounds" do
    expect do
      with_stubbed_class("SpecOptBadMaxRounds", workflow_class) do
        initial_state :idle
        state :done

        transition :translate, from: :idle, to: :done do
          optimize generator: :gen, evaluator: :eval, max_rounds: 0, evaluator_schema: Class.new
        end
      end
    end.to raise_error(workflow_error, /max_rounds must be a positive integer/)
  end

  it "rejects optimize declaration with no generator" do
    expect do
      with_stubbed_class("SpecOptNoGenerator", workflow_class) do
        initial_state :idle
        state :done

        transition :translate, from: :idle, to: :done do
          optimize generator: nil, evaluator: :eval, max_rounds: 3, evaluator_schema: Class.new
        end
      end
    end.to raise_error(workflow_error, /requires a generator/)
  end

  it "rejects optimize declaration with no evaluator" do
    expect do
      with_stubbed_class("SpecOptNoEvaluator", workflow_class) do
        initial_state :idle
        state :done

        transition :translate, from: :idle, to: :done do
          optimize generator: :gen, evaluator: nil, max_rounds: 3, evaluator_schema: Class.new
        end
      end
    end.to raise_error(workflow_error, /requires an evaluator/)
  end

  it "rejects optimize declaration with no evaluator_schema" do
    expect do
      with_stubbed_class("SpecOptNoSchema", workflow_class) do
        initial_state :idle
        state :done

        transition :translate, from: :idle, to: :done do
          optimize generator: :gen, evaluator: :eval, max_rounds: 3, evaluator_schema: nil
        end
      end
    end.to raise_error(workflow_error, /requires an evaluator_schema/)
  end

  it "rejects combining optimize with execute" do
    expect do
      with_stubbed_class("SpecOptDualExecute", workflow_class) do
        initial_state :idle
        state :done

        transition :translate, from: :idle, to: :done do
          execute :some_agent
          optimize generator: :gen, evaluator: :eval, max_rounds: 3, evaluator_schema: Class.new
        end
      end
    end.to raise_error(workflow_error, /cannot declare both optimize and execute/)
  end

  it "keeps parent step count as one across all optimization rounds" do
    generator = with_stubbed_class("SpecOptGenStepCount", agent_class) do
      register_as :spec_opt_gen_step_count
      model "gpt-5-mini"
    end
    evaluator = with_stubbed_class("SpecOptEvalStepCount", agent_class) do
      register_as :spec_opt_eval_step_count
      model "gpt-5-mini"
    end

    stub_agent_sequence(generator, %w[draft1 draft2 draft3])
    stub_agent_sequence(evaluator, [
                          { accept: false, feedback: "try again", score: 0.5 },
                          { accept: false, feedback: "better", score: 0.7 },
                          { accept: true, feedback: nil, score: 0.95 }
                        ])

    schema = Class.new

    workflow = with_stubbed_class("SpecOptStepCountWorkflow", workflow_class) do
      initial_state :idle
      state :done
      state :failed

      transition :translate, from: :idle, to: :done do
        optimize generator: :spec_opt_gen_step_count, evaluator: :spec_opt_eval_step_count,
                 max_rounds: 5, evaluator_schema: schema
        on_failure :fail
      end
    end.new

    result = workflow.run!

    expect(result.state).to eq(:done)
    expect(result.output).to eq("draft3")
    expect(result.steps.length).to eq(1)
    expect(workflow.instance_variable_get(:@step_count)).to eq(1)
  end

  it "participates in normal serial budget reservation and reconciliation across optimization rounds" do
    generator = with_stubbed_class("SpecOptGenBudget", agent_class) do
      register_as :spec_opt_gen_budget
      model "gpt-5-mini"
    end
    evaluator = with_stubbed_class("SpecOptEvalBudget", agent_class) do
      register_as :spec_opt_eval_budget
      model "gpt-5-mini"
    end

    stub_agent_sequence(generator, %w[draft1 draft2])
    stub_agent_sequence(evaluator, [
                          { accept: false, feedback: "revise", score: 0.4 },
                          { accept: true, feedback: nil, score: 0.9 }
                        ])

    schema = Class.new

    workflow = with_stubbed_class("SpecOptBudgetWorkflow", workflow_class) do
      initial_state :idle
      state :done
      budget total_tokens: 100

      transition :translate, from: :idle, to: :done do
        optimize generator: :spec_opt_gen_budget, evaluator: :spec_opt_eval_budget,
                 max_rounds: 3, evaluator_schema: schema
      end
    end.new

    observed = Queue.new
    ledger = workflow.ledger

    allow(ledger).to receive(:reserve!).and_wrap_original do |original, key, amount|
      observed << [:reserve, key, amount]
      original.call(key, amount)
    end
    allow(ledger).to receive(:reconcile!).and_wrap_original do |original, reservation, actual_amount|
      key, reserved_amount = reservation.amounts.first
      observed << [:reconcile, key, reserved_amount, actual_amount]
      original.call(reservation, actual_amount)
    end
    allow(ledger).to receive(:release!).and_wrap_original do |original, reservation|
      key, amount = reservation.amounts.first
      observed << [:release, key, amount]
      original.call(reservation)
    end

    result = workflow.run!

    expect(result.state).to eq(:done)

    entries = []
    entries << observed.pop until observed.empty?

    expect(entries.select { |entry| entry[0] == :reserve }).to contain_exactly(
      [:reserve, :total_tokens, 100],
      [:reserve, :total_tokens, 92],
      [:reserve, :total_tokens, 84],
      [:reserve, :total_tokens, 76]
    )
    expect(entries.select { |entry| entry[0] == :reconcile }).to contain_exactly(
      [:reconcile, :total_tokens, 100, 8],
      [:reconcile, :total_tokens, 92, 8],
      [:reconcile, :total_tokens, 84, 8],
      [:reconcile, :total_tokens, 76, 8]
    )
    expect(entries.select { |entry| entry[0] == :release }).to eq([])
  end

  it "keeps refinement-round metadata in turn-local user content instead of adding another system message" do
    generator = with_stubbed_class("SpecOptGenPromptShape", agent_class) do
      register_as :spec_opt_gen_prompt_shape
      model "gpt-5-mini"

      instructions { "generator instructions" }
    end
    evaluator = with_stubbed_class("SpecOptEvalPromptShape", agent_class) do
      register_as :spec_opt_eval_prompt_shape
      model "gpt-5-mini"
    end

    generator_messages = Queue.new
    allow(generator).to receive(:chat) do
      chat = Object.new
      messages = [Struct.new(:role, :content).new(:system, "generator instructions")]

      chat.define_singleton_method(:messages) { messages }
      chat.define_singleton_method(:with_instructions) do |instructions|
        messages[0] = Struct.new(:role, :content).new(:system, instructions)
        self
      end
      chat.define_singleton_method(:add_message) do |message|
        messages << Struct.new(:role, :content).new(message[:role], message[:content])
      end
      chat.define_singleton_method(:with_schema) { |_s| self }
      chat.define_singleton_method(:complete) do
        generator_messages << messages.map { |msg| { role: msg.role, content: msg.content } }
        result = generator_messages.size == 1 ? "draft1" : "draft2"
        Struct.new(:content, :input_tokens, :output_tokens).new(result, 5, 3)
      end
      chat
    end

    stub_agent_sequence(evaluator, [
                          { accept: false, feedback: "tighten the structure", score: 0.5 },
                          { accept: true, feedback: nil, score: 0.95 }
                        ])

    schema = Class.new

    workflow = with_stubbed_class("SpecOptPromptShapeWorkflow", workflow_class) do
      initial_state :idle
      state :done
      state :failed

      transition :translate, from: :idle, to: :done do
        optimize generator: :spec_opt_gen_prompt_shape, evaluator: :spec_opt_eval_prompt_shape,
                 max_rounds: 3, evaluator_schema: schema
        on_failure :fail
      end
    end.new

    result = workflow.run!

    expect(result.state).to eq(:done)

    calls = []
    calls << generator_messages.pop until generator_messages.empty?

    expect(calls.length).to eq(2)
    expect(calls.last).to eq(
      [
        { role: :system, content: "generator instructions" },
        { role: :assistant, content: "draft1" },
        {
          role: :user,
          content: "[smith:refinement-round] 2\n[smith:evaluator-feedback]\ntighten the structure"
        }
      ]
    )
  end

  it "sends a structured candidate as JSON to the evaluator and in the refinement assistant turn" do
    generator = with_stubbed_class("SpecOptGenStructured", agent_class) do
      register_as :spec_opt_gen_structured
      model "gpt-5-mini"
    end
    evaluator = with_stubbed_class("SpecOptEvalStructured", agent_class) do
      register_as :spec_opt_eval_structured
      model "gpt-5-mini"
    end
    candidates = [{ "title" => "Draft 1", "tags" => ["a"] }, { "title" => "Draft 2", "tags" => ["b"] }]
    evaluations = [
      { accept: false, feedback: "shorter title", score: 0.4 },
      { accept: true, feedback: nil, score: 0.9 }
    ]
    recording_chat = lambda do |klass, results|
      inputs = Queue.new
      calls = Concurrent::AtomicFixnum.new(-1)
      allow(klass).to receive(:chat) do
        received = []
        result = results.fetch(calls.increment)
        chat = Object.new
        chat.define_singleton_method(:add_message) { |message| received << message }
        chat.define_singleton_method(:with_schema) { |_s| self }
        chat.define_singleton_method(:complete) do
          inputs << received
          Struct.new(:content, :input_tokens, :output_tokens).new(result, 5, 3)
        end
        chat
      end
      inputs
    end
    generator_inputs = recording_chat.call(generator, candidates)
    evaluator_inputs = recording_chat.call(evaluator, evaluations)

    workflow = with_stubbed_class("SpecOptStructuredWorkflow", workflow_class) do
      initial_state :idle
      state :done
      state :failed

      transition :draft, from: :idle, to: :done do
        optimize generator: :spec_opt_gen_structured, evaluator: :spec_opt_eval_structured,
                 max_rounds: 3, evaluator_schema: Class.new
        on_failure :fail
      end
    end.new

    result = workflow.run!
    evaluator_messages = Array.new(2) { evaluator_inputs.pop }
    refinement_messages = Array.new(2) { generator_inputs.pop }.last

    expect(result.output).to eq(candidates.last)
    expect(evaluator_messages.map { |messages| messages.last[:content] }).to eq(candidates.map { JSON.generate(_1) })
    expect(refinement_messages.find { |message| message[:role] == :assistant }[:content])
      .to eq(JSON.generate(candidates.first))
  end

  describe "evaluator output normalization (real RubyLLM schema responses use String keys)" do
    it "accepts a String-keyed Hash from a schema-bound evaluator and treats accept: true correctly" do
      generator = with_stubbed_class("SpecOptGenStringKeysAccept", agent_class) do
        register_as :spec_opt_gen_string_keys_accept
        model "gpt-5-mini"
      end
      evaluator = with_stubbed_class("SpecOptEvalStringKeysAccept", agent_class) do
        register_as :spec_opt_eval_string_keys_accept
        model "gpt-5-mini"
      end

      stub_agent(generator, "string-keys draft")
      stub_agent(evaluator, { "accept" => true, "feedback" => nil, "score" => 0.91 })

      schema = Class.new

      workflow = with_stubbed_class("SpecOptStringKeysAcceptWorkflow", workflow_class) do
        initial_state :idle
        state :done
        state :failed

        transition :translate, from: :idle, to: :done do
          optimize generator: :spec_opt_gen_string_keys_accept,
                   evaluator: :spec_opt_eval_string_keys_accept,
                   max_rounds: 3, evaluator_schema: schema
          on_failure :fail
        end
      end.new

      result = workflow.run!

      expect(result.state).to eq(:done)
      expect(result.output).to eq("string-keys draft")
    end

    it "accepts a JSON string from an evaluator that bypasses schema parsing" do
      generator = with_stubbed_class("SpecOptGenJsonString", agent_class) do
        register_as :spec_opt_gen_json_string
        model "gpt-5-mini"
      end
      evaluator = with_stubbed_class("SpecOptEvalJsonString", agent_class) do
        register_as :spec_opt_eval_json_string
        model "gpt-5-mini"
      end

      stub_agent(generator, "json-string draft")
      stub_agent(evaluator, '{"accept": true, "feedback": null, "score": 0.88}')

      schema = Class.new

      workflow = with_stubbed_class("SpecOptJsonStringWorkflow", workflow_class) do
        initial_state :idle
        state :done
        state :failed

        transition :translate, from: :idle, to: :done do
          optimize generator: :spec_opt_gen_json_string,
                   evaluator: :spec_opt_eval_json_string,
                   max_rounds: 3, evaluator_schema: schema
          on_failure :fail
        end
      end.new

      result = workflow.run!

      expect(result.state).to eq(:done)
      expect(result.output).to eq("json-string draft")
    end

    it "still raises a descriptive WorkflowError when a String evaluation isn't valid JSON" do
      generator = with_stubbed_class("SpecOptGenBadString", agent_class) do
        register_as :spec_opt_gen_bad_string
        model "gpt-5-mini"
      end
      evaluator = with_stubbed_class("SpecOptEvalBadString", agent_class) do
        register_as :spec_opt_eval_bad_string
        model "gpt-5-mini"
      end

      stub_agent(generator, "draft")
      stub_agent(evaluator, "not-json-just-prose")

      schema = Class.new

      workflow = with_stubbed_class("SpecOptBadStringWorkflow", workflow_class) do
        initial_state :idle
        state :done
        state :failed

        transition :translate, from: :idle, to: :done do
          optimize generator: :spec_opt_gen_bad_string,
                   evaluator: :spec_opt_eval_bad_string,
                   max_rounds: 2, evaluator_schema: schema
          on_failure :fail
        end
      end.new

      result = workflow.run!

      expect(result.state).to eq(:failed)
      expect(result.steps.first[:error]).to be_a(workflow_error)
      expect(result.steps.first[:error].message).to match(/Hash/)
    end
  end

  describe "evaluator_context: :inject_state" do
    it "appends the candidate as a user turn to the prepared_input the generator received" do
      generator = with_stubbed_class("SpecOptGenInject", agent_class) do
        register_as :spec_opt_gen_inject
        model "gpt-5-mini"
      end
      evaluator = with_stubbed_class("SpecOptEvalInject", agent_class) do
        register_as :spec_opt_eval_inject
        model "gpt-5-mini"
      end

      stub_agent(generator, "candidate prose")

      evaluator_inputs = Queue.new
      allow(evaluator).to receive(:chat) do
        messages = []
        chat = Object.new
        chat.define_singleton_method(:messages) { messages }
        chat.define_singleton_method(:with_instructions) do |instructions|
          messages.unshift({ role: :system, content: instructions })
          self
        end
        chat.define_singleton_method(:add_message) { |m| messages << { role: m[:role], content: m[:content] } }
        chat.define_singleton_method(:with_schema) { |_s| self }
        chat.define_singleton_method(:complete) do
          evaluator_inputs << messages.dup
          Struct.new(:content, :input_tokens, :output_tokens).new({ accept: true, feedback: nil, score: 0.95 }, 5, 3)
        end
        chat
      end

      schema = Class.new
      ctx_klass = with_stubbed_class("SpecOptInjectContext", require_const("Smith::Context")) do
        inject_state { |_persisted| "voice contract goes here" }
      end

      workflow = with_stubbed_class("SpecOptInjectWorkflow", workflow_class) do
        initial_state :idle
        state :done
        state :failed
        context_manager ctx_klass

        transition :translate, from: :idle, to: :done do
          optimize generator: :spec_opt_gen_inject, evaluator: :spec_opt_eval_inject,
                   max_rounds: 3, evaluator_schema: schema, evaluator_context: :inject_state
          on_failure :fail
        end
      end.new

      result = workflow.run!

      expect(result.state).to eq(:done)
      seen = []
      seen << evaluator_inputs.pop until evaluator_inputs.empty?

      expect(seen.length).to eq(1)
      # Candidate appended LAST, prior inject_state observations precede it
      expect(seen.first.last).to eq(role: :user, content: "candidate prose")
      expect(seen.first.any? { |m| m[:content].to_s.include?("voice contract goes here") }).to be true
    end

    it "rejects an unknown evaluator_context value at workflow load time" do
      expect do
        with_stubbed_class("SpecOptBadEvalContext", workflow_class) do
          initial_state :idle
          state :done

          transition :translate, from: :idle, to: :done do
            optimize generator: :gen, evaluator: :eval, max_rounds: 3,
                     evaluator_schema: Class.new, evaluator_context: :wat
          end
        end
      end.to raise_error(workflow_error, /evaluator_context must be nil or :inject_state/)
    end
  end

  describe "before_eval: callback" do
    it "runs the callback after the candidate is generated and before the evaluator is invoked" do
      generator = with_stubbed_class("SpecOptGenBeforeEval", agent_class) do
        register_as :spec_opt_gen_before_eval
        model "gpt-5-mini"
      end
      evaluator = with_stubbed_class("SpecOptEvalBeforeEval", agent_class) do
        register_as :spec_opt_eval_before_eval
        model "gpt-5-mini"
      end

      stub_agent(generator, "candidate")

      observed = []
      stub_agent(evaluator, { accept: true, feedback: nil, score: 0.9 })

      schema = Class.new

      workflow = with_stubbed_class("SpecOptBeforeEvalWorkflow", workflow_class) do
        initial_state :idle
        state :done
        state :failed

        transition :translate, from: :idle, to: :done do
          optimize generator: :spec_opt_gen_before_eval, evaluator: :spec_opt_eval_before_eval,
                   max_rounds: 3, evaluator_schema: schema,
                   before_eval: ->(state, context) {
                     observed << [state.candidate, context.dup]
                     context[:violations] = ["fake violation"]
                   }
          on_failure :fail
        end
      end.new

      result = workflow.run!

      expect(result.state).to eq(:done)
      expect(observed.length).to eq(1)
      expect(observed.first[0]).to eq("candidate")
      expect(workflow.instance_variable_get(:@context)[:violations]).to eq(["fake violation"])
    end

    it "lets a raised exception bubble through the standard step failure path" do
      generator = with_stubbed_class("SpecOptGenBeforeEvalRaise", agent_class) do
        register_as :spec_opt_gen_before_eval_raise
        model "gpt-5-mini"
      end
      evaluator = with_stubbed_class("SpecOptEvalBeforeEvalRaise", agent_class) do
        register_as :spec_opt_eval_before_eval_raise
        model "gpt-5-mini"
      end

      stub_agent(generator, "candidate")
      stub_agent(evaluator, { accept: true, feedback: nil, score: 0.9 })

      schema = Class.new

      workflow = with_stubbed_class("SpecOptBeforeEvalRaiseWorkflow", workflow_class) do
        initial_state :idle
        state :done
        state :failed

        transition :translate, from: :idle, to: :done do
          optimize generator: :spec_opt_gen_before_eval_raise,
                   evaluator: :spec_opt_eval_before_eval_raise,
                   max_rounds: 3, evaluator_schema: schema,
                   before_eval: ->(_s, _c) { raise "validator blew up" }
          on_failure :fail
        end
      end.new

      result = workflow.run!

      expect(result.state).to eq(:failed)
      expect(result.steps.first[:error].message).to include("validator blew up")
    end

    it "rejects a non-callable before_eval at workflow load time" do
      expect do
        with_stubbed_class("SpecOptBadBeforeEval", workflow_class) do
          initial_state :idle
          state :done

          transition :translate, from: :idle, to: :done do
            optimize generator: :gen, evaluator: :eval, max_rounds: 3,
                     evaluator_schema: Class.new, before_eval: "not callable"
          end
        end
      end.to raise_error(workflow_error, /before_eval must respond to :call/)
    end

    def recording_chat(inputs, result)
      received = []
      chat = Object.new
      chat.define_singleton_method(:add_message) { |message| received << message }
      chat.define_singleton_method(:with_schema) { |_s| self }
      chat.define_singleton_method(:complete) do
        inputs << received
        Struct.new(:content, :input_tokens, :output_tokens).new(result, 5, 3)
      end
      chat
    end

    def record_inputs(klass, results)
      inputs = Queue.new
      calls = Concurrent::AtomicFixnum.new(-1)
      allow(klass).to receive(:chat) do
        recording_chat(inputs, results.fetch([calls.increment, results.length - 1].min))
      end
      inputs
    end

    def before_eval_agents(label)
      %w[Gen Eval].map do |role|
        agent_name = :"spec_before_eval_#{label.downcase}_#{role.downcase}"
        with_stubbed_class("SpecBeforeEval#{label}#{role}", agent_class) do
          register_as agent_name
          model "gpt-5-mini"
        end
      end
    end

    def before_eval_workflow(label, before_eval, agents: label, **options)
      prefix = "spec_before_eval_#{agents.downcase}"
      with_stubbed_class("SpecBeforeEval#{label}Workflow", workflow_class) do
        initial_state :idle
        state :done
        state :failed

        transition :draft, from: :idle, to: :done do
          optimize generator: :"#{prefix}_gen", evaluator: :"#{prefix}_eval",
                   max_rounds: 2, evaluator_schema: Class.new, before_eval:, **options
          on_failure :fail
        end
      end.new
    end

    it "counts a returned rejection as the round's evaluation, skipping the evaluator and refining with its feedback" do
      generator, evaluator = before_eval_agents("Reject")
      generator_inputs = record_inputs(generator, ["draft one", "draft two"])
      evaluator_inputs = record_inputs(evaluator, [{ accept: true, feedback: nil }])
      verdicts = [{ "accept" => false, "feedback" => "cite the source" }, nil]
      seen = []
      before_eval = lambda do |state, _context|
        seen << state.candidate
        verdicts.shift
      end

      result = before_eval_workflow("Reject", before_eval).run!
      generator_calls = Array.new(generator_inputs.size) { generator_inputs.pop }
      evaluator_calls = Array.new(evaluator_inputs.size) { evaluator_inputs.pop }

      expect(result.output).to eq("draft two")
      expect(seen).to eq(["draft one", "draft two"])
      expect(evaluator_calls.map { |messages| messages.last[:content] }).to eq(["draft two"])
      expect(generator_calls.last.last[:content])
        .to eq("[smith:refinement-round] 2\n[smith:evaluator-feedback]\ncite the source")
    end

    it "attributes a rejected round's usage and provider calls to its generator alone" do
      generator, evaluator = before_eval_agents("Attribution")
      record_inputs(generator, ["draft one", "draft two"])
      record_inputs(evaluator, [{ accept: true, feedback: nil }])
      verdicts = [{ accept: false, feedback: "cite the source" }, nil]
      workflow = before_eval_workflow("Attribution", ->(_state, _context) { verdicts.shift })
      trace_adapter = Smith::Trace::Memory.new
      original_adapter = Smith.config.trace_adapter

      begin
        Smith.configure { |config| config.trace_adapter = trace_adapter }
        result = workflow.run!
      ensure
        Smith.configure { |config| config.trace_adapter = original_adapter }
      end

      expected = [
        [:spec_before_eval_attribution_gen, 0], [:spec_before_eval_attribution_gen, 1],
        [:spec_before_eval_attribution_eval, 1]
      ]
      provider_calls = trace_adapter.traces.select { |trace| trace[:type] == :provider_call }.map { _1[:data] }
      expect(result.usage_entries.map { |entry| [entry.agent_name, entry.round] }).to eq(expected)
      expect(provider_calls.map { |data| [data[:agent_name], data[:round]] }).to eq(expected)
    end

    it "exhausts through on_exhaustion when before_eval rejects every round" do
      generator, evaluator = before_eval_agents("Exhaust")
      stub_agent(generator, "draft")
      stub_agent(evaluator, { accept: true, feedback: nil })

      rejecting = before_eval_workflow("Exhaust", ->(_state, _context) { { accept: false, feedback: "never" } })
      last = before_eval_workflow(
        "ExhaustLast", ->(_state, _context) { { accept: false, feedback: "never" } },
        agents: "Exhaust", on_exhaustion: :return_last
      )
      result = rejecting.run!

      expect(result.state).to eq(:failed)
      expect(result.steps.first[:error].message).to eq("optimization exhausted 2 rounds without acceptance")
      expect(last.run!.output).to eq("draft")
      expect(generator).to have_received(:chat).exactly(4).times
      expect(evaluator).not_to have_received(:chat)
    end

    it "validates a returned rejection exactly as evaluator output" do
      generator, evaluator = before_eval_agents("Invalid")
      stub_agent(generator, "draft")
      stub_agent(evaluator, { accept: true, feedback: nil, score: 0.9 })

      unexplained = before_eval_workflow("Invalid", ->(_state, _context) { { accept: false } })
      unscored = before_eval_workflow(
        "Unscored", ->(_state, _context) { { accept: false, feedback: "why" } },
        agents: "Invalid", improvement_threshold: 0.1
      )
      messages = [unexplained, unscored].map { |workflow| workflow.run!.steps.first[:error].message }

      expect(messages).to eq(
        [
          "evaluator must provide :feedback when not accepted",
          "evaluator must provide numeric :score when improvement_threshold is configured"
        ]
      )
      expect(evaluator).not_to have_received(:chat)
    end

    it "ignores any other return value, so the evaluator still judges" do
      generator, evaluator = before_eval_agents("Ignored")
      stub_agent(generator, "draft")
      stub_agent(evaluator, { accept: true, feedback: nil })
      returns = [
        nil, "review text", ["violation"], { accept: true, feedback: "fine" }, { "accept" => true },
        { verdict: false }, { accept: "false", feedback: "not a boolean" }
      ]

      outputs = returns.each_with_index.map do |value, index|
        before_eval_workflow("Ignored#{index}", ->(_state, _context) { value }, agents: "Ignored").run!.output
      end

      expect(outputs).to eq(["draft"] * returns.length)
      expect(evaluator).to have_received(:chat).exactly(returns.length).times
    end
  end

  describe "graceful-exit modes" do
    it "on_exhaustion: :return_last returns the last candidate as the step output" do
      generator = with_stubbed_class("SpecOptGenReturnLastExhaust", agent_class) do
        register_as :spec_opt_gen_return_last_exhaust
        model "gpt-5-mini"
      end
      evaluator = with_stubbed_class("SpecOptEvalReturnLastExhaust", agent_class) do
        register_as :spec_opt_eval_return_last_exhaust
        model "gpt-5-mini"
      end

      stub_agent_sequence(generator, %w[round1 round2])
      stub_agent(evaluator, { accept: false, feedback: "more work", score: 0.5 })

      schema = Class.new

      workflow = with_stubbed_class("SpecOptReturnLastExhaustWorkflow", workflow_class) do
        initial_state :idle
        state :done
        state :failed

        transition :translate, from: :idle, to: :done do
          optimize generator: :spec_opt_gen_return_last_exhaust,
                   evaluator: :spec_opt_eval_return_last_exhaust,
                   max_rounds: 2, evaluator_schema: schema,
                   on_exhaustion: :return_last
          on_failure :fail
        end
      end.new

      result = workflow.run!

      expect(result.state).to eq(:done)
      expect(result.output).to eq("round2")
    end

    it "on_converged: :return_last returns the most recent candidate on a converged signal" do
      generator = with_stubbed_class("SpecOptGenReturnLastConverged", agent_class) do
        register_as :spec_opt_gen_return_last_converged
        model "gpt-5-mini"
      end
      evaluator = with_stubbed_class("SpecOptEvalReturnLastConverged", agent_class) do
        register_as :spec_opt_eval_return_last_converged
        model "gpt-5-mini"
      end

      stub_agent(generator, "single-round")
      stub_agent(evaluator, { accept: false, feedback: "minor", converged: true, score: 0.9 })

      schema = Class.new

      workflow = with_stubbed_class("SpecOptReturnLastConvergedWorkflow", workflow_class) do
        initial_state :idle
        state :done
        state :failed

        transition :translate, from: :idle, to: :done do
          optimize generator: :spec_opt_gen_return_last_converged,
                   evaluator: :spec_opt_eval_return_last_converged,
                   max_rounds: 5, evaluator_schema: schema,
                   on_converged: :return_last
          on_failure :fail
        end
      end.new

      result = workflow.run!

      expect(result.state).to eq(:done)
      expect(result.output).to eq("single-round")
    end

    it "on_threshold: :return_last returns the most recent candidate on plateau" do
      generator = with_stubbed_class("SpecOptGenReturnLastThreshold", agent_class) do
        register_as :spec_opt_gen_return_last_threshold
        model "gpt-5-mini"
      end
      evaluator = with_stubbed_class("SpecOptEvalReturnLastThreshold", agent_class) do
        register_as :spec_opt_eval_return_last_threshold
        model "gpt-5-mini"
      end

      stub_agent_sequence(generator, %w[draft1 draft2])
      stub_agent_sequence(evaluator, [
        { accept: false, feedback: "try again", score: 0.7 },
        { accept: false, feedback: "still", score: 0.71 }
      ])

      schema = Class.new

      workflow = with_stubbed_class("SpecOptReturnLastThresholdWorkflow", workflow_class) do
        initial_state :idle
        state :done
        state :failed

        transition :translate, from: :idle, to: :done do
          optimize generator: :spec_opt_gen_return_last_threshold,
                   evaluator: :spec_opt_eval_return_last_threshold,
                   max_rounds: 5, evaluator_schema: schema,
                   improvement_threshold: 0.05,
                   on_threshold: :return_last
          on_failure :fail
        end
      end.new

      result = workflow.run!

      expect(result.state).to eq(:done)
      expect(result.output).to eq("draft2")
    end

    it "accepts a callable mode and uses its return value as the step output" do
      generator = with_stubbed_class("SpecOptGenCallableExit", agent_class) do
        register_as :spec_opt_gen_callable_exit
        model "gpt-5-mini"
      end
      evaluator = with_stubbed_class("SpecOptEvalCallableExit", agent_class) do
        register_as :spec_opt_eval_callable_exit
        model "gpt-5-mini"
      end

      stub_agent(generator, "draft")
      stub_agent(evaluator, { accept: false, feedback: "needs work", score: 0.5 })

      schema = Class.new

      workflow = with_stubbed_class("SpecOptCallableExitWorkflow", workflow_class) do
        initial_state :idle
        state :done
        state :failed

        transition :translate, from: :idle, to: :done do
          optimize generator: :spec_opt_gen_callable_exit,
                   evaluator: :spec_opt_eval_callable_exit,
                   max_rounds: 1, evaluator_schema: schema,
                   on_exhaustion: ->(state) { { candidate: state.candidate, soft_fail: true } }
          on_failure :fail
        end
      end.new

      result = workflow.run!

      expect(result.state).to eq(:done)
      expect(result.output).to eq(candidate: "draft", soft_fail: true)
    end

    it "rejects invalid exit-mode symbols at workflow load time" do
      expect do
        with_stubbed_class("SpecOptBadExitMode", workflow_class) do
          initial_state :idle
          state :done

          transition :translate, from: :idle, to: :done do
            optimize generator: :gen, evaluator: :eval, max_rounds: 3,
                     evaluator_schema: Class.new, on_exhaustion: :wat
          end
        end
      end.to raise_error(workflow_error, /on_exhaustion must be :raise, :return_last, or a callable/)
    end
  end

  describe "verdicts as an output" do
    def verdict_agents(label)
      %w[Gen Eval].map do |role|
        with_stubbed_class("SpecVerdict#{label}#{role}", agent_class) do
          register_as :"spec_verdict_#{label.downcase}_#{role.downcase}"
          model "gpt-5-mini"
        end
      end
    end

    def verdict_workflow(label, agents: label, max_rounds: 2, retry_on_agent_error: false, **options)
      prefix = "spec_verdict_#{agents.downcase}"
      with_stubbed_class("SpecVerdict#{label}Workflow", workflow_class) do
        idempotency_mode :strict
        initial_state :idle
        state :drafted
        state :done
        state :failed

        transition :draft, from: :idle, to: :drafted do
          optimize generator: :"#{prefix}_gen", evaluator: :"#{prefix}_eval",
                   max_rounds:, evaluator_schema: Class.new, **options
          retry_on Smith::AgentError, attempts: 2, backoff: 0 if retry_on_agent_error
          on_failure :fail
        end

        transition :finish, from: :drafted, to: :done do
          compute { |_step| nil }
        end
      end.new
    end

    it "records every round's verdict and who gave it on the step, and the run result names its transition" do
      generator, evaluator = verdict_agents("Rounds")
      stub_agent_sequence(generator, ["draft one", "draft two"])
      stub_agent(evaluator, { "accept" => true, "feedback" => "ok", "score" => 0.9, "notes" => ["tight"] })
      verdicts = [{ "accept" => false, "feedback" => "cite the source" }, nil]

      result = verdict_workflow("Rounds", before_eval: ->(_state, _context) { verdicts.shift }).run!
      expected = [
        { attempt: 1, round: 0, source: :before_eval, verdict: { accept: false, feedback: "cite the source" } },
        { attempt: 1, round: 1, source: :evaluator,
          verdict: { accept: true, feedback: "ok", score: 0.9, notes: ["tight"] } }
      ]

      expect(result.state).to eq(:done)
      expect(result.steps.first[:evaluations]).to eq(expected)
      expect(result.steps.last).not_to have_key(:evaluations)
      expect(result.evaluations).to eq(expected.map { |evaluation| { transition: :draft, **evaluation } })
    end

    it "keeps the verdict that ends a failed loop, and hands an exit callable every verdict so far" do
      generator, evaluator = verdict_agents("Exhaust")
      stub_agent(generator, "draft")
      stub_agent_sequence(evaluator, [{ accept: false, feedback: "first" }, { accept: false, feedback: "second" }])
      seen = nil
      failed = verdict_workflow("Exhaust").run!
      stub_agent_sequence(evaluator, [{ accept: false, feedback: "first" }, { accept: false, feedback: "second" }])
      exit = lambda do |state|
        seen = state.evaluations.map { |evaluation| evaluation[:verdict][:feedback] }
        state.candidate
      end
      kept = verdict_workflow("ExhaustCallable", agents: "Exhaust", on_exhaustion: exit).run!

      expect(failed.state).to eq(:failed)
      expect(failed.steps.first[:error].message).to eq("optimization exhausted 2 rounds without acceptance")
      expect(failed.evaluations.map { |evaluation| [evaluation[:round], evaluation[:verdict][:feedback]] })
        .to eq([[0, "first"], [1, "second"]])
      expect(seen).to eq(%w[first second])
      expect(kept.steps.first[:evaluations].length).to eq(2)
    end

    it "keeps the verdict that converges the loop" do
      generator, evaluator = verdict_agents("Converged")
      stub_agent(generator, "draft")
      stub_agent(evaluator, { accept: false, feedback: "as good as it gets", converged: true })

      result = verdict_workflow("Converged", max_rounds: 3, on_converged: :return_last).run!

      expect(result.output).to eq("draft")
      expect(result.evaluations.map { |evaluation| evaluation[:verdict] })
        .to eq([{ accept: false, feedback: "as good as it gets", converged: true }])
    end

    it "freezes each verdict apart from what the evaluator returned" do
      generator, evaluator = verdict_agents("Frozen")
      feedback = +"ok"
      stub_agent(generator, "draft")
      stub_agent(evaluator, { accept: true, feedback: feedback, notes: [+"kept"] })

      record = verdict_workflow("Frozen").run!.steps.first[:evaluations].first
      feedback << " changed"

      expect(record[:verdict][:feedback]).to eq("ok")
      expect([record, record[:verdict], record[:verdict][:feedback], record[:verdict][:notes],
              record[:verdict][:notes].first]).to all(be_frozen)
    end

    it "fails the round when a verdict holds a value that is not JSON, in every run mode alike" do
      generator, evaluator = verdict_agents("Json")
      stub_agent(generator, "draft")
      stub_agent(evaluator, { accept: true, feedback: "ok" })
      odd = [
        { accept: false, feedback: "x", issues: [Object.new] },
        { accept: false, feedback: "x", score: Float::NAN },
        { accept: false, feedback: "x", details: { 1 => "one" } }
      ]

      messages = odd.each_with_index.map do |verdict, index|
        result = verdict_workflow("Json#{index}", agents: "Json", before_eval: ->(_state, _context) { verdict }).run!
        expect(result.state).to eq(:failed)
        result.steps.first[:error].message
      end

      expect(messages).to eq(
        [
          "evaluation must hold JSON values; got Object",
          "evaluation must hold finite numbers; got NaN",
          "evaluation keys must be Strings or Symbols; got Integer"
        ]
      )
    end

    it "hands a callable a frozen copy, so it cannot rewrite the step's verdicts" do
      generator, evaluator = verdict_agents("Callable")
      stub_agent(generator, "draft")
      stub_agent(evaluator, { accept: false, feedback: "no" })
      exit = lambda do |state|
        expect(state.evaluations).to be_frozen
        state.evaluations = []
        state.candidate
      end

      result = verdict_workflow("Callable", on_exhaustion: exit).run!

      expect(result.state).to eq(:done)
      expect(result.evaluations.length).to eq(2)
      expect(result.evaluations).to all(be_frozen)
    end

    it "gives a step that failed before its loop no verdicts" do
      result = verdict_workflow("Unregistered", agents: "NeverRegistered").run!

      expect(result.state).to eq(:failed)
      expect(result.steps.first).not_to have_key(:evaluations)
      expect(result.evaluations).to eq([])
    end

    it "keeps every attempt's verdicts when the step is retried, each naming its attempt" do
      generator, evaluator = verdict_agents("Retried")
      stub_agent(generator, "draft")
      answers = [{ accept: false, feedback: "first attempt" }, Smith::AgentError.new("outage"),
                 { accept: true, feedback: "second attempt" }]
      allow(evaluator).to receive(:chat) do
        answer = answers.shift
        Object.new.tap do |chat|
          chat.define_singleton_method(:add_message) { |_message| nil }
          chat.define_singleton_method(:with_schema) { |_schema| self }
          chat.define_singleton_method(:complete) do
            raise answer if answer.is_a?(Exception)

            Struct.new(:content, :input_tokens, :output_tokens).new(answer, 5, 3)
          end
        end
      end

      result = verdict_workflow("Retried", retry_on_agent_error: true).run!

      expect(result.state).to eq(:done)
      expect(answers).to be_empty
      said = result.evaluations.map do |evaluation|
        [*evaluation.values_at(:attempt, :round), evaluation[:verdict][:feedback]]
      end
      expect(said).to eq([[1, 0, "first attempt"], [2, 0, "second attempt"]])
    end

    it "carries the verdicts through a strict persisted run and a split step's snapshot" do
      generator, evaluator = verdict_agents("Persisted")
      stub_agent(generator, "draft")
      stub_agent(evaluator, { accept: true, feedback: "ok" })
      adapter = Smith::PersistenceAdapters::Memory.new
      expected = [{ attempt: 1, round: 0, source: :evaluator, verdict: { accept: true, feedback: "ok" } }]

      persisted = verdict_workflow("Persisted").run_persisted!("verdicts:persisted", adapter:)
      split = verdict_workflow("PersistedSplit", agents: "Persisted")
      split.prepare_persisted_step!("verdicts:split", adapter:)
      step = split.execute_prepared_step!

      expect(persisted.state).to eq(:done)
      expect(persisted.evaluations).to eq(expected.map { |evaluation| { transition: :draft, **evaluation } })
      expect(step[:evaluations]).to eq(expected)
    end

    it "fails a non-JSON verdict at its round in a split step as well" do
      generator, evaluator = verdict_agents("SplitJson")
      stub_agent(generator, "draft")
      stub_agent(evaluator, { accept: true, feedback: "ok" })
      odd = ->(_state, _context) { { accept: false, feedback: Object.new } }
      split = verdict_workflow("SplitJson", before_eval: odd)

      split.prepare_persisted_step!("verdicts:split-json", adapter: Smith::PersistenceAdapters::Memory.new)
      step = split.execute_prepared_step!

      expect(step[:error].message).to eq("evaluation must hold JSON values; got Object")
      expect(step[:evaluations]).to eq([])
    end

    it "fails the round whose verdict takes the step's past a step record's limits, in every run mode" do
      generator, evaluator = verdict_agents("Heavy")
      stub_agent(generator, "draft")
      stub_agent(evaluator, { accept: true, feedback: "ok" })
      long = "y" * ((Smith::Workflow::ExecutionResultSnapshot::MAX_BYTES / 2) + 10)
      verdicts = -> { [{ accept: false, feedback: long }, { accept: false, feedback: long }] }
      plain_verdicts = verdicts.call
      split_verdicts = verdicts.call

      plain = verdict_workflow("Heavy", max_rounds: 3, before_eval: ->(_state, _context) { plain_verdicts.shift }).run!
      split = verdict_workflow("HeavySplit", agents: "Heavy", max_rounds: 3,
                                             before_eval: ->(_state, _context) { split_verdicts.shift })
      split.prepare_persisted_step!("verdicts:heavy", adapter: Smith::PersistenceAdapters::Memory.new)
      step = split.execute_prepared_step!

      expect(plain.state).to eq(:failed)
      expect([plain.last_error.message, step[:error].message])
        .to all(start_with("evaluations exceed a step record's limits"))
      expect([plain.evaluations.length, step[:evaluations].length]).to eq([1, 1])
      expect(split.state).to eq(:failed)
    end

    it "keeps the verdicts on the failure record when a split step's completion fails" do
      generator, evaluator = verdict_agents("Oversize")
      stub_agent(generator, "x" * (Smith::Workflow::ExecutionResultSnapshot::MAX_BYTES + 1))
      stub_agent(evaluator, { accept: true, feedback: "ok" })
      split = verdict_workflow("Oversize")

      split.prepare_persisted_step!("verdicts:oversize", adapter: Smith::PersistenceAdapters::Memory.new)
      step = split.execute_prepared_step!

      expect(step[:error].message).to include("exceeds maximum bytes")
      expect(step[:evaluations]).to eq([{ attempt: 1, round: 0, source: :evaluator,
                                          verdict: { accept: true, feedback: "ok" } }])
    end

    it "names the attempt under way when an earlier attempt failed before its loop" do
      generator, evaluator = verdict_agents("Late")
      stub_agent(generator, "draft")
      stub_agent(evaluator, { accept: true, feedback: "ok" })
      calls = 0
      guards = with_stubbed_class("SpecVerdictLateGuards", require_const("Smith::Guardrails")) do
        define_method(:flaky) do |_payload|
          calls += 1
          raise Smith::AgentError, "transient" if calls == 1
        end
        input :flaky
      end

      workflow = with_stubbed_class("SpecVerdictLateWorkflow", workflow_class) do
        initial_state :idle
        state :drafted
        state :failed
        guardrails guards

        transition :draft, from: :idle, to: :drafted do
          optimize generator: :spec_verdict_late_gen, evaluator: :spec_verdict_late_eval,
                   max_rounds: 2, evaluator_schema: Class.new
          retry_on Smith::AgentError, attempts: 2, backoff: 0
          on_failure :fail
        end
      end

      result = workflow.new.run!

      expect(result.state).to eq(:drafted)
      expect(result.evaluations.map { |evaluation| evaluation.values_at(:attempt, :round) }).to eq([[2, 0]])
    end
  end
end
