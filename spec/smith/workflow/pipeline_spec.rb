# frozen_string_literal: true

RSpec.describe "Smith::Workflow::Pipeline runtime behavior" do
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

  it "executes pipeline stages in declared order" do
    order = Queue.new

    research = with_stubbed_class("SpecPipelineResearchAgent", agent_class) do
      register_as :spec_pipeline_research_agent
      model "gpt-5-mini"
    end
    outline = with_stubbed_class("SpecPipelineOutlineAgent", agent_class) do
      register_as :spec_pipeline_outline_agent
      model "gpt-5-mini"
    end
    draft = with_stubbed_class("SpecPipelineDraftAgent", agent_class) do
      register_as :spec_pipeline_draft_agent
      model "gpt-5-mini"
    end

    [research, outline, draft].zip(%i[research outline draft]).each do |ag, label|
      allow(ag).to receive(:chat) do
        order << label
        chat = Object.new
        chat.define_singleton_method(:add_message) { |_| nil }
        chat.define_singleton_method(:complete) do
          Struct.new(:content, :input_tokens, :output_tokens).new(label.to_s, 5, 3)
        end
        chat
      end
    end

    workflow = with_stubbed_class("SpecPipelineOrderWorkflow", workflow_class) do
      initial_state :idle
      state :drafted
      state :failed

      pipeline :draft_article, from: :idle, to: :drafted do
        stage :research, execute: :spec_pipeline_research_agent
        stage :outline, execute: :spec_pipeline_outline_agent
        stage :draft, execute: :spec_pipeline_draft_agent
        on_failure :fail
      end
    end.new

    result = workflow.run!

    expect(result.state).to eq(:drafted)

    observed = []
    observed << order.pop until order.empty?
    expect(observed).to eq(%i[research outline draft])
    expect(result.steps.length).to eq(3)
  end

  it "surfaces the last stage output as the workflow result" do
    agent = with_stubbed_class("SpecPipelineOutputAgent", agent_class) do
      register_as :spec_pipeline_output_agent
      model "gpt-5-mini"
    end

    call_count = Concurrent::AtomicFixnum.new(0)
    allow(agent).to receive(:chat) do
      n = call_count.increment
      chat = Object.new
      chat.define_singleton_method(:add_message) { |_| nil }
      chat.define_singleton_method(:complete) do
        Struct.new(:content, :input_tokens, :output_tokens).new("stage_#{n}_output", 5, 3)
      end
      chat
    end

    workflow = with_stubbed_class("SpecPipelineOutputWorkflow", workflow_class) do
      initial_state :idle
      state :done

      pipeline :process, from: :idle, to: :done do
        stage :first, execute: :spec_pipeline_output_agent
        stage :second, execute: :spec_pipeline_output_agent
      end
    end.new

    result = workflow.run!

    expect(result.state).to eq(:done)
    expect(result.output).to eq("stage_2_output")
  end

  it "routes through on_failure when a pipeline stage fails" do
    agent = with_stubbed_class("SpecPipelineFailAgent", agent_class) do
      register_as :spec_pipeline_fail_agent
      model "gpt-5-mini"
    end

    allow(agent).to receive(:chat) do
      chat = Object.new
      chat.define_singleton_method(:add_message) { |_| nil }
      chat.define_singleton_method(:complete) { raise StandardError, "provider error" }
      chat
    end

    workflow = with_stubbed_class("SpecPipelineFailWorkflow", workflow_class) do
      initial_state :idle
      state :done
      state :failed

      pipeline :process, from: :idle, to: :done do
        stage :first, execute: :spec_pipeline_fail_agent
        stage :second, execute: :spec_pipeline_fail_agent
        on_failure :fail
      end
    end.new

    result = workflow.run!

    expect(result.state).to eq(:failed)
    expect(result.steps.length).to eq(1)
    expect(result.steps.first[:error]).to be_a(Smith::AgentError)
  end

  it "rejects a pipeline with no stages" do
    expect do
      with_stubbed_class("SpecPipelineEmptyWorkflow", workflow_class) do
        initial_state :idle
        state :done

        pipeline :empty, from: :idle, to: :done do
          on_failure :fail
        end
      end
    end.to raise_error(workflow_error, /at least one stage/)
  end

  it "rejects a pipeline with no name" do
    expect do
      with_stubbed_class("SpecPipelineMissingNameWorkflow", workflow_class) do
        initial_state :idle
        state :done

        pipeline nil, from: :idle, to: :done do
          stage :first, execute: :spec_pipeline_output_agent
        end
      end
    end.to raise_error(workflow_error, /pipeline name is required/)
  end

  it "rejects a pipeline with no from state" do
    expect do
      with_stubbed_class("SpecPipelineMissingFromWorkflow", workflow_class) do
        initial_state :idle
        state :done

        pipeline :missing_from, from: nil, to: :done do
          stage :first, execute: :spec_pipeline_output_agent
        end
      end
    end.to raise_error(workflow_error, /requires from:/)
  end

  it "rejects a pipeline with no to state" do
    expect do
      with_stubbed_class("SpecPipelineMissingToWorkflow", workflow_class) do
        initial_state :idle
        state :done

        pipeline :missing_to, from: :idle, to: nil do
          stage :first, execute: :spec_pipeline_output_agent
        end
      end
    end.to raise_error(workflow_error, /requires to:/)
  end

  it "rejects a stage with no name" do
    expect do
      with_stubbed_class("SpecPipelineMissingStageNameWorkflow", workflow_class) do
        initial_state :idle
        state :done

        pipeline :missing_stage_name, from: :idle, to: :done do
          stage nil, execute: :spec_pipeline_output_agent
        end
      end
    end.to raise_error(workflow_error, /stage name is required/)
  end

  it "rejects a stage with no execute agent" do
    expect do
      with_stubbed_class("SpecPipelineMissingExecuteWorkflow", workflow_class) do
        initial_state :idle
        state :done

        pipeline :missing_execute, from: :idle, to: :done do
          stage :first, execute: nil
        end
      end
    end.to raise_error(workflow_error, /requires execute:/)
  end

  it "rejects duplicate stage names within a pipeline" do
    agent = with_stubbed_class("SpecPipelineDupAgent", agent_class) do
      register_as :spec_pipeline_dup_agent
      model "gpt-5-mini"
    end

    expect do
      with_stubbed_class("SpecPipelineDupWorkflow", workflow_class) do
        initial_state :idle
        state :done

        pipeline :dup, from: :idle, to: :done do
          stage :first, execute: :spec_pipeline_dup_agent
          stage :first, execute: :spec_pipeline_dup_agent
        end
      end
    end.to raise_error(workflow_error, /duplicate stage :first/)
  end

  it "rejects generated transitions that collide with existing transitions" do
    agent = with_stubbed_class("SpecPipelineCollisionAgent", agent_class) do
      register_as :spec_pipeline_collision_agent
      model "gpt-5-mini"
    end

    expect do
      with_stubbed_class("SpecPipelineCollisionWorkflow", workflow_class) do
        initial_state :idle
        state :done

        transition :process__first, from: :idle, to: :done

        pipeline :process, from: :idle, to: :done do
          stage :first, execute: :spec_pipeline_collision_agent
        end
      end
    end.to raise_error(workflow_error, /collides with existing transition/)
  end

  it "generates correct intermediate transitions with on_success chaining" do
    agent = with_stubbed_class("SpecPipelineChainingAgent", agent_class) do
      register_as :spec_pipeline_chaining_agent
      model "gpt-5-mini"
    end

    klass = with_stubbed_class("SpecPipelineChainingWorkflow", workflow_class) do
      initial_state :idle
      state :done

      pipeline :flow, from: :idle, to: :done do
        stage :a, execute: :spec_pipeline_chaining_agent
        stage :b, execute: :spec_pipeline_chaining_agent
        stage :c, execute: :spec_pipeline_chaining_agent
      end
    end

    t_a = klass.find_transition(:flow__a)
    t_b = klass.find_transition(:flow__b)
    t_c = klass.find_transition(:flow__c)

    expect(t_a).not_to be_nil
    expect(t_a.from).to eq(:idle)
    expect(t_a.to).to eq(:flow__after_a)
    expect(t_a.success_transition).to eq(:flow__b)

    expect(t_b).not_to be_nil
    expect(t_b.from).to eq(:flow__after_a)
    expect(t_b.to).to eq(:flow__after_b)
    expect(t_b.success_transition).to eq(:flow__c)

    expect(t_c).not_to be_nil
    expect(t_c.from).to eq(:flow__after_b)
    expect(t_c.to).to eq(:done)
    expect(t_c.success_transition).to be_nil
  end
end
