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
    allow(ledger).to receive(:reconcile!).and_wrap_original do |original, key, reserved_amount, actual_amount|
      observed << [:reconcile, key, reserved_amount, actual_amount]
      original.call(key, reserved_amount, actual_amount)
    end
    allow(ledger).to receive(:release!).and_wrap_original do |original, key, amount|
      observed << [:release, key, amount]
      original.call(key, amount)
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
end
