# frozen_string_literal: true

SpecOwLooseSchema = Class.new { def self.required_keys = [] }
SpecOwTaskSchema = Class.new { def self.required_keys = %i[task_id input] }
SpecOwWorkerOutputSchema = Class.new { def self.required_keys = %i[finding] }
SpecOwFinalOutputSchema = Class.new { def self.required_keys = %i[summary] }

RSpec.describe "Smith::Workflow::OrchestratorWorker runtime behavior" do
  let(:agent_class) { require_const("Smith::Agent") }
  let(:workflow_class) { require_const("Smith::Workflow") }
  let(:workflow_error) { require_const("Smith::WorkflowError") }

  def stub_agent_sequence(klass, results)
    idx = Concurrent::AtomicFixnum.new(-1)
    allow(klass).to receive(:chat) do
      i = idx.increment
      result = results[i] || results.last
      chat = Object.new
      chat.define_singleton_method(:add_message) { |_msg| nil }
      chat.define_singleton_method(:with_schema) { |_s| self }
      chat.define_singleton_method(:complete) do
        Struct.new(:content, :input_tokens, :output_tokens).new(result, 5, 3)
      end
      chat
    end
  end

  it "succeeds when orchestrator emits valid final output" do
    orchestrator = with_stubbed_class("SpecOwOrch1", agent_class) do
      register_as :spec_ow_orch_1
      model "gpt-5-mini"
    end
    worker = with_stubbed_class("SpecOwWork1", agent_class) do
      register_as :spec_ow_work_1
      model "gpt-5-mini"
    end

    stub_agent_sequence(orchestrator, [{ final: { summary: "done", findings: %w[a b] } }])

    workflow = with_stubbed_class("SpecOwFinalWorkflow", workflow_class) do
      initial_state :idle
      state :done
      state :failed

      transition :research, from: :idle, to: :done do
        orchestrate orchestrator: :spec_ow_orch_1, worker: :spec_ow_work_1,
                    max_workers: 4, max_delegation_rounds: 3,
                    task_schema: SpecOwTaskSchema,
                    worker_output_schema: SpecOwWorkerOutputSchema,
                    final_output_schema: SpecOwFinalOutputSchema
        on_failure :fail
      end
    end.new

    result = workflow.run!

    expect(result.state).to eq(:done)
    expect(result.output).to eq({ summary: "done", findings: %w[a b] })
    expect(result.steps.length).to eq(1)
  end

  it "runs workers and feeds results back to orchestrator" do
    orchestrator = with_stubbed_class("SpecOwOrch2", agent_class) do
      register_as :spec_ow_orch_2
      model "gpt-5-mini"
    end
    worker = with_stubbed_class("SpecOwWork2", agent_class) do
      register_as :spec_ow_work_2
      model "gpt-5-mini"
    end

    stub_agent_sequence(orchestrator, [
                          { tasks: [{ task_id: "t1", input: "research pricing" }] },
                          { final: { summary: "complete" } }
                        ])
    stub_agent_sequence(worker, [{ finding: "pricing is competitive" }])

    workflow = with_stubbed_class("SpecOwTaskWorkflow", workflow_class) do
      initial_state :idle
      state :done
      state :failed

      transition :research, from: :idle, to: :done do
        orchestrate orchestrator: :spec_ow_orch_2, worker: :spec_ow_work_2,
                    max_workers: 4, max_delegation_rounds: 3,
                    task_schema: SpecOwTaskSchema,
                    worker_output_schema: SpecOwWorkerOutputSchema,
                    final_output_schema: SpecOwFinalOutputSchema
        on_failure :fail
      end
    end.new

    result = workflow.run!

    expect(result.state).to eq(:done)
    expect(result.output).to eq({ summary: "complete" })
  end

  it "fails when max_delegation_rounds exhausted without final output" do
    orchestrator = with_stubbed_class("SpecOwOrch3", agent_class) do
      register_as :spec_ow_orch_3
      model "gpt-5-mini"
    end
    worker = with_stubbed_class("SpecOwWork3", agent_class) do
      register_as :spec_ow_work_3
      model "gpt-5-mini"
    end

    stub_agent_sequence(orchestrator, [{ tasks: [{ task_id: "t1", input: "work" }] }])
    stub_agent_sequence(worker, [{ finding: "partial" }])

    workflow = with_stubbed_class("SpecOwExhaustWorkflow", workflow_class) do
      initial_state :idle
      state :done
      state :failed

      transition :research, from: :idle, to: :done do
        orchestrate orchestrator: :spec_ow_orch_3, worker: :spec_ow_work_3,
                    max_workers: 4, max_delegation_rounds: 2,
                    task_schema: SpecOwTaskSchema,
                    worker_output_schema: SpecOwWorkerOutputSchema,
                    final_output_schema: SpecOwFinalOutputSchema
        on_failure :fail
      end
    end.new

    result = workflow.run!

    expect(result.state).to eq(:failed)
    expect(result.steps.first[:error]).to be_a(workflow_error)
    expect(result.steps.first[:error].message).to include("exhausted 2 rounds")
  end

  it "fails when tasks exceed max_workers" do
    orchestrator = with_stubbed_class("SpecOwOrch4", agent_class) do
      register_as :spec_ow_orch_4
      model "gpt-5-mini"
    end
    worker = with_stubbed_class("SpecOwWork4", agent_class) do
      register_as :spec_ow_work_4
      model "gpt-5-mini"
    end

    stub_agent_sequence(orchestrator, [{ tasks: [{ id: 1 }, { id: 2 }, { id: 3 }] }])

    workflow = with_stubbed_class("SpecOwMaxWorkersWorkflow", workflow_class) do
      initial_state :idle
      state :done
      state :failed

      transition :research, from: :idle, to: :done do
        orchestrate orchestrator: :spec_ow_orch_4, worker: :spec_ow_work_4,
                    max_workers: 2, max_delegation_rounds: 3,
                    task_schema: SpecOwTaskSchema,
                    worker_output_schema: SpecOwWorkerOutputSchema,
                    final_output_schema: SpecOwFinalOutputSchema
        on_failure :fail
      end
    end.new

    result = workflow.run!

    expect(result.state).to eq(:failed)
    expect(result.steps.first[:error].message).to include("exceeds max_workers")
  end

  it "fails loudly when the configured orchestrator agent symbol is not registered" do
    worker = with_stubbed_class("SpecOwRegisteredWorkerOnly", agent_class) do
      register_as :spec_ow_registered_worker_only
      model "gpt-5-mini"
    end

    stub_agent_sequence(worker, [{ finding: "partial" }])

    workflow = with_stubbed_class("SpecOwMissingOrchestratorWorkflow", workflow_class) do
      initial_state :idle
      state :done
      state :failed

      transition :research, from: :idle, to: :done do
        orchestrate orchestrator: :missing_orchestrator_agent, worker: :spec_ow_registered_worker_only,
                    max_workers: 2, max_delegation_rounds: 2,
                    task_schema: SpecOwTaskSchema,
                    worker_output_schema: SpecOwWorkerOutputSchema,
                    final_output_schema: SpecOwFinalOutputSchema
        on_failure :fail
      end
    end.new

    result = workflow.run!

    expect(result.state).to eq(:failed)
    expect(result.steps.first[:error]).to be_a(workflow_error)
    expect(result.steps.first[:error].message).to include("unresolved orchestrator :missing_orchestrator_agent")
    expect(result.steps.first[:error].message).to include("transition :research")
  end

  it "fails loudly when the configured worker agent symbol is not registered" do
    orchestrator = with_stubbed_class("SpecOwRegisteredOrchestratorOnly", agent_class) do
      register_as :spec_ow_registered_orchestrator_only
      model "gpt-5-mini"
    end

    stub_agent_sequence(orchestrator, [{ tasks: [{ topic: "follow-up" }] }])

    workflow = with_stubbed_class("SpecOwMissingWorkerWorkflow", workflow_class) do
      initial_state :idle
      state :done
      state :failed

      transition :research, from: :idle, to: :done do
        orchestrate orchestrator: :spec_ow_registered_orchestrator_only, worker: :missing_worker_agent,
                    max_workers: 2, max_delegation_rounds: 2,
                    task_schema: SpecOwTaskSchema,
                    worker_output_schema: SpecOwWorkerOutputSchema,
                    final_output_schema: SpecOwFinalOutputSchema
        on_failure :fail
      end
    end.new

    result = workflow.run!

    expect(result.state).to eq(:failed)
    expect(result.steps.first[:error]).to be_a(workflow_error)
    expect(result.steps.first[:error].message).to include("unresolved worker :missing_worker_agent")
    expect(result.steps.first[:error].message).to include("transition :research")
  end

  it "fails when orchestrator emits stop signal" do
    orchestrator = with_stubbed_class("SpecOwOrch5", agent_class) do
      register_as :spec_ow_orch_5
      model "gpt-5-mini"
    end
    worker = with_stubbed_class("SpecOwWork5", agent_class) do
      register_as :spec_ow_work_5
      model "gpt-5-mini"
    end

    stub_agent_sequence(orchestrator, [{ stop: "insufficient signal" }])

    workflow = with_stubbed_class("SpecOwStopWorkflow", workflow_class) do
      initial_state :idle
      state :done
      state :failed

      transition :research, from: :idle, to: :done do
        orchestrate orchestrator: :spec_ow_orch_5, worker: :spec_ow_work_5,
                    max_workers: 4, max_delegation_rounds: 3,
                    task_schema: SpecOwTaskSchema,
                    worker_output_schema: SpecOwWorkerOutputSchema,
                    final_output_schema: SpecOwFinalOutputSchema
        on_failure :fail
      end
    end.new

    result = workflow.run!

    expect(result.state).to eq(:failed)
    expect(result.steps.first[:error].message).to include("stopped")
  end

  it "fails when orchestrator emits both tasks and final" do
    orchestrator = with_stubbed_class("SpecOwOrch6", agent_class) do
      register_as :spec_ow_orch_6
      model "gpt-5-mini"
    end
    worker = with_stubbed_class("SpecOwWork6", agent_class) do
      register_as :spec_ow_work_6
      model "gpt-5-mini"
    end

    stub_agent_sequence(orchestrator, [{ tasks: [{ id: 1 }], final: { done: true } }])

    workflow = with_stubbed_class("SpecOwAmbiguousWorkflow", workflow_class) do
      initial_state :idle
      state :done
      state :failed

      transition :research, from: :idle, to: :done do
        orchestrate orchestrator: :spec_ow_orch_6, worker: :spec_ow_work_6,
                    max_workers: 4, max_delegation_rounds: 3,
                    task_schema: SpecOwTaskSchema,
                    worker_output_schema: SpecOwWorkerOutputSchema,
                    final_output_schema: SpecOwFinalOutputSchema
        on_failure :fail
      end
    end.new

    result = workflow.run!

    expect(result.state).to eq(:failed)
    expect(result.steps.first[:error].message).to include("exactly one")
  end

  it "fails when orchestrator output is not a Hash" do
    orchestrator = with_stubbed_class("SpecOwOrch7", agent_class) do
      register_as :spec_ow_orch_7
      model "gpt-5-mini"
    end
    worker = with_stubbed_class("SpecOwWork7", agent_class) do
      register_as :spec_ow_work_7
      model "gpt-5-mini"
    end

    stub_agent_sequence(orchestrator, ["not a hash"])

    workflow = with_stubbed_class("SpecOwNonHashWorkflow", workflow_class) do
      initial_state :idle
      state :done
      state :failed

      transition :research, from: :idle, to: :done do
        orchestrate orchestrator: :spec_ow_orch_7, worker: :spec_ow_work_7,
                    max_workers: 4, max_delegation_rounds: 3,
                    task_schema: SpecOwTaskSchema,
                    worker_output_schema: SpecOwWorkerOutputSchema,
                    final_output_schema: SpecOwFinalOutputSchema
        on_failure :fail
      end
    end.new

    result = workflow.run!

    expect(result.state).to eq(:failed)
    expect(result.steps.first[:error].message).to include("must be a Hash")
  end

  it "keeps parent step count as one across all orchestration rounds" do
    orchestrator = with_stubbed_class("SpecOwOrch8", agent_class) do
      register_as :spec_ow_orch_8
      model "gpt-5-mini"
    end
    worker = with_stubbed_class("SpecOwWork8", agent_class) do
      register_as :spec_ow_work_8
      model "gpt-5-mini"
    end

    stub_agent_sequence(orchestrator, [
                          { tasks: [{ task_id: "t1", input: "a" }, { task_id: "t2", input: "b" }] },
                          { final: { summary: "done" } }
                        ])
    stub_agent_sequence(worker, [{ finding: "x" }, { finding: "y" }])

    workflow = with_stubbed_class("SpecOwStepCountWorkflow", workflow_class) do
      initial_state :idle
      state :done
      state :failed

      transition :research, from: :idle, to: :done do
        orchestrate orchestrator: :spec_ow_orch_8, worker: :spec_ow_work_8,
                    max_workers: 4, max_delegation_rounds: 3,
                    task_schema: SpecOwTaskSchema,
                    worker_output_schema: SpecOwWorkerOutputSchema,
                    final_output_schema: SpecOwFinalOutputSchema
        on_failure :fail
      end
    end.new

    result = workflow.run!

    expect(result.state).to eq(:done)
    expect(result.steps.length).to eq(1)
    expect(workflow.instance_variable_get(:@step_count)).to eq(1)
  end

  it "rejects malformed declaration with non-positive max_workers" do
    expect do
      with_stubbed_class("SpecOwBadMaxWorkers", workflow_class) do
        initial_state :idle
        state :done

        transition :research, from: :idle, to: :done do
          orchestrate orchestrator: :o, worker: :w, max_workers: 0, max_delegation_rounds: 3,
                      task_schema: SpecOwLooseSchema, worker_output_schema: SpecOwLooseSchema, final_output_schema: SpecOwLooseSchema
        end
      end
    end.to raise_error(workflow_error, /max_workers must be a positive integer/)
  end

  it "rejects malformed declaration with missing orchestrator" do
    expect do
      with_stubbed_class("SpecOwNoOrch", workflow_class) do
        initial_state :idle
        state :done

        transition :research, from: :idle, to: :done do
          orchestrate orchestrator: nil, worker: :w, max_workers: 4, max_delegation_rounds: 3,
                      task_schema: SpecOwLooseSchema, worker_output_schema: SpecOwLooseSchema, final_output_schema: SpecOwLooseSchema
        end
      end
    end.to raise_error(workflow_error, /requires an orchestrator/)
  end

  it "rejects malformed declaration with missing worker" do
    expect do
      with_stubbed_class("SpecOwNoWorker", workflow_class) do
        initial_state :idle
        state :done

        transition :research, from: :idle, to: :done do
          orchestrate orchestrator: :o, worker: nil, max_workers: 4, max_delegation_rounds: 3,
                      task_schema: SpecOwLooseSchema, worker_output_schema: SpecOwLooseSchema, final_output_schema: SpecOwLooseSchema
        end
      end
    end.to raise_error(workflow_error, /requires a worker/)
  end

  it "rejects malformed declaration with missing task_schema" do
    expect do
      with_stubbed_class("SpecOwNoTaskSchema", workflow_class) do
        initial_state :idle
        state :done

        transition :research, from: :idle, to: :done do
          orchestrate orchestrator: :o, worker: :w, max_workers: 4, max_delegation_rounds: 3,
                      task_schema: nil, worker_output_schema: SpecOwLooseSchema, final_output_schema: SpecOwLooseSchema
        end
      end
    end.to raise_error(workflow_error, /requires a task_schema/)
  end

  it "rejects malformed declaration with missing worker_output_schema" do
    expect do
      with_stubbed_class("SpecOwNoWorkerSchema", workflow_class) do
        initial_state :idle
        state :done

        transition :research, from: :idle, to: :done do
          orchestrate orchestrator: :o, worker: :w, max_workers: 4, max_delegation_rounds: 3,
                      task_schema: SpecOwLooseSchema, worker_output_schema: nil, final_output_schema: SpecOwLooseSchema
        end
      end
    end.to raise_error(workflow_error, /requires a worker_output_schema/)
  end

  it "rejects malformed declaration with missing final_output_schema" do
    expect do
      with_stubbed_class("SpecOwNoFinalSchema", workflow_class) do
        initial_state :idle
        state :done

        transition :research, from: :idle, to: :done do
          orchestrate orchestrator: :o, worker: :w, max_workers: 4, max_delegation_rounds: 3,
                      task_schema: SpecOwLooseSchema, worker_output_schema: SpecOwLooseSchema, final_output_schema: nil
        end
      end
    end.to raise_error(workflow_error, /requires a final_output_schema/)
  end

  it "rejects malformed declaration when schema surface does not expose required_keys" do
    expect do
      with_stubbed_class("SpecOwBadSchemaSurface", workflow_class) do
        initial_state :idle
        state :done

        transition :research, from: :idle, to: :done do
          orchestrate orchestrator: :o, worker: :w, max_workers: 4, max_delegation_rounds: 3,
                      task_schema: Class.new, worker_output_schema: SpecOwLooseSchema, final_output_schema: SpecOwLooseSchema
        end
      end
    end.to raise_error(workflow_error, /task_schema must respond to :required_keys/)
  end

  it "rejects malformed declaration with non-positive max_delegation_rounds" do
    expect do
      with_stubbed_class("SpecOwBadDelegationRounds", workflow_class) do
        initial_state :idle
        state :done

        transition :research, from: :idle, to: :done do
          orchestrate orchestrator: :o, worker: :w, max_workers: 4, max_delegation_rounds: 0,
                      task_schema: SpecOwLooseSchema, worker_output_schema: SpecOwLooseSchema, final_output_schema: SpecOwLooseSchema
        end
      end
    end.to raise_error(workflow_error, /max_delegation_rounds must be a positive integer/)
  end

  it "rejects combining orchestrate with execute" do
    expect do
      with_stubbed_class("SpecOwDualExecute", workflow_class) do
        initial_state :idle
        state :done

        transition :research, from: :idle, to: :done do
          execute :some_agent
          orchestrate orchestrator: :o, worker: :w, max_workers: 4, max_delegation_rounds: 3,
                      task_schema: SpecOwLooseSchema, worker_output_schema: SpecOwLooseSchema, final_output_schema: SpecOwLooseSchema
        end
      end
    end.to raise_error(workflow_error, /cannot declare both/)
  end

  it "rejects combining orchestrate with route" do
    expect do
      with_stubbed_class("SpecOwDualRoute", workflow_class) do
        initial_state :idle
        state :done

        transition :research, from: :idle, to: :done do
          route :classifier, routes: { a: :done }, confidence_threshold: 0.8, fallback: :done
          orchestrate orchestrator: :o, worker: :w, max_workers: 4, max_delegation_rounds: 3,
                      task_schema: SpecOwLooseSchema, worker_output_schema: SpecOwLooseSchema, final_output_schema: SpecOwLooseSchema
        end
      end
    end.to raise_error(workflow_error, /cannot declare both/)
  end

  it "rejects combining orchestrate with workflow" do
    child = with_stubbed_class("SpecOwChildWorkflow", workflow_class) do
      initial_state :idle
      state :done
      transition :finish, from: :idle, to: :done
    end

    expect do
      with_stubbed_class("SpecOwDualWorkflow", workflow_class) do
        initial_state :idle
        state :done

        transition :research, from: :idle, to: :done do
          workflow child
          orchestrate orchestrator: :o, worker: :w, max_workers: 4, max_delegation_rounds: 3,
                      task_schema: SpecOwLooseSchema, worker_output_schema: SpecOwLooseSchema, final_output_schema: SpecOwLooseSchema
        end
      end
    end.to raise_error(workflow_error, /cannot declare both/)
  end

  it "rejects combining orchestrate with optimize" do
    expect do
      with_stubbed_class("SpecOwDualOptimize", workflow_class) do
        initial_state :idle
        state :done

        transition :research, from: :idle, to: :done do
          optimize generator: :g, evaluator: :e, max_rounds: 3, evaluator_schema: Class.new
          orchestrate orchestrator: :o, worker: :w, max_workers: 4, max_delegation_rounds: 3,
                      task_schema: SpecOwLooseSchema, worker_output_schema: SpecOwLooseSchema, final_output_schema: SpecOwLooseSchema
        end
      end
    end.to raise_error(workflow_error, /cannot declare both/)
  end

  it "fails when orchestrator emits both tasks and stop" do
    orchestrator = with_stubbed_class("SpecOwOrchTasksStop", agent_class) do
      register_as :spec_ow_orch_tasks_stop
      model "gpt-5-mini"
    end
    worker = with_stubbed_class("SpecOwWorkTasksStop", agent_class) do
      register_as :spec_ow_work_tasks_stop
      model "gpt-5-mini"
    end

    stub_agent_sequence(orchestrator, [{ tasks: [{ task_id: "t1", input: "x" }], stop: "halt" }])

    workflow = with_stubbed_class("SpecOwTasksStopWorkflow", workflow_class) do
      initial_state :idle
      state :done
      state :failed

      transition :research, from: :idle, to: :done do
        orchestrate orchestrator: :spec_ow_orch_tasks_stop, worker: :spec_ow_work_tasks_stop,
                    max_workers: 4, max_delegation_rounds: 3,
                    task_schema: SpecOwTaskSchema, worker_output_schema: SpecOwWorkerOutputSchema, final_output_schema: SpecOwFinalOutputSchema
        on_failure :fail
      end
    end.new

    result = workflow.run!

    expect(result.state).to eq(:failed)
    expect(result.steps.first[:error].message).to include("exactly one")
  end

  it "fails when orchestrator emits both final and stop" do
    orchestrator = with_stubbed_class("SpecOwOrchFinalStop", agent_class) do
      register_as :spec_ow_orch_final_stop
      model "gpt-5-mini"
    end
    worker = with_stubbed_class("SpecOwWorkFinalStop", agent_class) do
      register_as :spec_ow_work_final_stop
      model "gpt-5-mini"
    end

    stub_agent_sequence(orchestrator, [{ final: { summary: "done" }, stop: "halt" }])

    workflow = with_stubbed_class("SpecOwFinalStopWorkflow", workflow_class) do
      initial_state :idle
      state :done
      state :failed

      transition :research, from: :idle, to: :done do
        orchestrate orchestrator: :spec_ow_orch_final_stop, worker: :spec_ow_work_final_stop,
                    max_workers: 4, max_delegation_rounds: 3,
                    task_schema: SpecOwTaskSchema, worker_output_schema: SpecOwWorkerOutputSchema, final_output_schema: SpecOwFinalOutputSchema
        on_failure :fail
      end
    end.new

    result = workflow.run!

    expect(result.state).to eq(:failed)
    expect(result.steps.first[:error].message).to include("exactly one")
  end

  it "fails when worker task payload violates task_schema" do
    orchestrator = with_stubbed_class("SpecOwOrchBadTask", agent_class) do
      register_as :spec_ow_orch_bad_task
      model "gpt-5-mini"
    end
    worker = with_stubbed_class("SpecOwWorkBadTask", agent_class) do
      register_as :spec_ow_work_bad_task
      model "gpt-5-mini"
    end

    stub_agent_sequence(orchestrator, [{ tasks: [{ task_id: "t1" }] }])

    workflow = with_stubbed_class("SpecOwBadTaskWorkflow", workflow_class) do
      initial_state :idle
      state :done
      state :failed

      transition :research, from: :idle, to: :done do
        orchestrate orchestrator: :spec_ow_orch_bad_task, worker: :spec_ow_work_bad_task,
                    max_workers: 4, max_delegation_rounds: 3,
                    task_schema: SpecOwTaskSchema, worker_output_schema: SpecOwWorkerOutputSchema, final_output_schema: SpecOwFinalOutputSchema
        on_failure :fail
      end
    end.new

    result = workflow.run!

    expect(result.state).to eq(:failed)
    expect(result.steps.first[:error].message).to include("worker task missing required keys: input")
  end

  it "fails when worker output violates worker_output_schema" do
    orchestrator = with_stubbed_class("SpecOwOrchBadOutput", agent_class) do
      register_as :spec_ow_orch_bad_output
      model "gpt-5-mini"
    end
    worker = with_stubbed_class("SpecOwWorkBadOutput", agent_class) do
      register_as :spec_ow_work_bad_output
      model "gpt-5-mini"
    end

    stub_agent_sequence(orchestrator, [{ tasks: [{ task_id: "t1", input: "research" }] }])
    stub_agent_sequence(worker, [{ note: "missing finding" }])

    workflow = with_stubbed_class("SpecOwBadOutputWorkflow", workflow_class) do
      initial_state :idle
      state :done
      state :failed

      transition :research, from: :idle, to: :done do
        orchestrate orchestrator: :spec_ow_orch_bad_output, worker: :spec_ow_work_bad_output,
                    max_workers: 4, max_delegation_rounds: 3,
                    task_schema: SpecOwTaskSchema, worker_output_schema: SpecOwWorkerOutputSchema, final_output_schema: SpecOwFinalOutputSchema
        on_failure :fail
      end
    end.new

    result = workflow.run!

    expect(result.state).to eq(:failed)
    expect(result.steps.first[:error].message).to include("worker output missing required keys: finding")
  end

  it "fails when final output violates final_output_schema" do
    orchestrator = with_stubbed_class("SpecOwOrchBadFinal", agent_class) do
      register_as :spec_ow_orch_bad_final
      model "gpt-5-mini"
    end
    worker = with_stubbed_class("SpecOwWorkBadFinal", agent_class) do
      register_as :spec_ow_work_bad_final
      model "gpt-5-mini"
    end

    stub_agent_sequence(orchestrator, [{ final: { findings: %w[a] } }])

    workflow = with_stubbed_class("SpecOwBadFinalWorkflow", workflow_class) do
      initial_state :idle
      state :done
      state :failed

      transition :research, from: :idle, to: :done do
        orchestrate orchestrator: :spec_ow_orch_bad_final, worker: :spec_ow_work_bad_final,
                    max_workers: 4, max_delegation_rounds: 3,
                    task_schema: SpecOwTaskSchema, worker_output_schema: SpecOwWorkerOutputSchema, final_output_schema: SpecOwFinalOutputSchema
        on_failure :fail
      end
    end.new

    result = workflow.run!

    expect(result.state).to eq(:failed)
    expect(result.steps.first[:error].message).to include("final output missing required keys: summary")
  end

  it "routes through on_failure when a worker execution fails" do
    orchestrator = with_stubbed_class("SpecOwOrchWorkerFailure", agent_class) do
      register_as :spec_ow_orch_worker_failure
      model "gpt-5-mini"
    end
    worker = with_stubbed_class("SpecOwWorkWorkerFailure", agent_class) do
      register_as :spec_ow_work_worker_failure
      model "gpt-5-mini"
    end

    workflow_error = require_const("Smith::WorkflowError")

    stub_agent_sequence(orchestrator, [{ tasks: [{ task_id: "t1", input: "research" }] }])
    bad_chat = Object.new
    bad_chat.define_singleton_method(:add_message) { |_msg| nil }
    bad_chat.define_singleton_method(:with_schema) { |_s| self }
    bad_chat.define_singleton_method(:complete) do
      raise workflow_error, "worker failed"
    end
    allow(worker).to receive(:chat).and_return(bad_chat)

    workflow = with_stubbed_class("SpecOwWorkerFailureWorkflow", workflow_class) do
      initial_state :idle
      state :done
      state :failed

      transition :research, from: :idle, to: :done do
        orchestrate orchestrator: :spec_ow_orch_worker_failure, worker: :spec_ow_work_worker_failure,
                    max_workers: 4, max_delegation_rounds: 3,
                    task_schema: SpecOwTaskSchema, worker_output_schema: SpecOwWorkerOutputSchema, final_output_schema: SpecOwFinalOutputSchema
        on_failure :fail
      end
    end.new

    result = workflow.run!

    expect(result.state).to eq(:failed)
    expect(result.steps.first[:error]).to be_a(workflow_error)
    expect(result.steps.first[:error].message).to include("worker failed")
  end
end
