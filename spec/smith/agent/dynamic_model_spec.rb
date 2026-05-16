# frozen_string_literal: true

# Block-form `model` DSL — resolves at chat-construction time using the
# workflow's `@context`. Decision #34 in AGENT_GEM_ARCHITECTURE.md.
#
# Mirrors the test voice of `agent/fallback_spec.rb`: workflow-driven
# integration tests (run!), agent.chat stubbed to capture the model_id
# Smith resolved per attempt.
RSpec.describe "Smith::Agent block-form model DSL" do
  let(:agent_class) { require_const("Smith::Agent") }
  let(:workflow_class) { require_const("Smith::Workflow") }
  let(:agent_error) { require_const("Smith::AgentError") }

  def stubbed_chat(content, input_tokens: 5, output_tokens: 3, on_complete: nil)
    chat = Object.new
    chat.define_singleton_method(:add_message) { |_| nil }
    chat.define_singleton_method(:with_schema) { |_| self }
    chat.define_singleton_method(:complete) do
      on_complete&.call
      Struct.new(:content, :input_tokens, :output_tokens).new(content, input_tokens, output_tokens)
    end
    chat
  end

  describe "static form (regression)" do
    it "stores the static model in chat_kwargs and leaves model_block nil" do
      agent = with_stubbed_class("SpecStaticModelAgent", agent_class) do
        model "gpt-5-mini"
      end

      expect(agent.chat_kwargs[:model]).to eq("gpt-5-mini")
      expect(agent.model_block).to be_nil
    end

    it "still drives the workflow with the declared static model" do
      agent = with_stubbed_class("SpecStaticDriveAgent", agent_class) do
        register_as :spec_static_drive
        model "gpt-5-mini"
      end

      models_tried = []
      allow(agent).to receive(:chat) do |**kwargs|
        models_tried << kwargs[:model]
        stubbed_chat("static-ok")
      end

      workflow = with_stubbed_class("SpecStaticDriveWorkflow", workflow_class) do
        initial_state :idle; state :done
        transition :go, from: :idle, to: :done do execute :spec_static_drive end
      end.new
      result = workflow.run!

      expect(result.state).to eq(:done)
      expect(models_tried).to eq(%w[gpt-5-mini])
    end
  end

  describe "block-form storage" do
    it "stores the block when model is given a block" do
      agent = with_stubbed_class("SpecBlockStorageAgent", agent_class) do
        model { |_ctx| "gpt-5.5" }
      end

      expect(agent.model_block).to be_a(Proc)
      expect(agent.chat_kwargs[:model]).to be_nil
    end

    it "raises ArgumentError when both a string and a block are passed to model" do
      expect do
        with_stubbed_class("SpecBothFormsAgent", agent_class) do
          model("gpt-5-mini") { |_ctx| "gpt-5.5" }
        end
      end.to raise_error(ArgumentError, /string id OR a block/)
    end

    it "redeclaring static after block clears the block" do
      agent = with_stubbed_class("SpecRedeclareStaticAgent", agent_class) do
        model { |_ctx| "gpt-5.5" }
        model "gpt-5-mini"
      end

      expect(agent.model_block).to be_nil
      expect(agent.chat_kwargs[:model]).to eq("gpt-5-mini")
    end

    it "redeclaring block after static clears the static" do
      agent = with_stubbed_class("SpecRedeclareBlockAgent", agent_class) do
        model "gpt-5-mini"
        model { |_ctx| "gpt-5.5" }
      end

      expect(agent.model_block).to be_a(Proc)
      expect(agent.chat_kwargs[:model]).to be_nil
    end
  end

  describe "resolution at chat-construction time" do
    it "evaluates the block with the workflow's @context and uses the returned model id" do
      agent = with_stubbed_class("SpecResolveContextAgent", agent_class) do
        register_as :spec_resolve_context
        model { |ctx| ctx[:form_kind] == "article" ? "claude-opus-4-7" : "gpt-5.5" }
      end

      models_tried = []
      allow(agent).to receive(:chat) do |**kwargs|
        models_tried << kwargs[:model]
        stubbed_chat("ok")
      end

      workflow_def = with_stubbed_class("SpecResolveContextWorkflow", workflow_class) do
        initial_state :idle; state :done
        transition :go, from: :idle, to: :done do execute :spec_resolve_context end
      end

      article_workflow = workflow_def.new(context: { form_kind: "article" })
      article_workflow.run!

      short_form_workflow = workflow_def.new(context: { form_kind: "single_post" })
      short_form_workflow.run!

      expect(models_tried).to eq(%w[claude-opus-4-7 gpt-5.5])
    end

    it "treats an empty workflow context (the default) as a Hash so blocks can read keys without NoMethodError" do
      agent = with_stubbed_class("SpecResolveDefaultCtxAgent", agent_class) do
        register_as :spec_resolve_default_ctx
        model { |ctx| ctx[:override_model] || "gpt-5.5" }
      end

      allow(agent).to receive(:chat) { stubbed_chat("ok") }

      workflow = with_stubbed_class("SpecResolveDefaultCtxWorkflow", workflow_class) do
        initial_state :idle; state :done
        transition :go, from: :idle, to: :done do execute :spec_resolve_default_ctx end
      end.new

      expect { workflow.run! }.not_to raise_error
      expect(workflow.run!.output).to eq("ok")
    end
  end

  describe "block-form composition with fallback_models" do
    it "uses the resolved primary, then declared fallbacks, in order" do
      agent = with_stubbed_class("SpecBlockFallbackAgent", agent_class) do
        register_as :spec_block_fallback
        model { |ctx| ctx[:primary] }
        fallback_models "gpt-5-mini", "gpt-4.1-mini"
      end

      models_tried = []
      allow(agent).to receive(:chat) do |**kwargs|
        models_tried << kwargs[:model]
        if kwargs[:model] == "gpt-5.5"
          chat = Object.new
          chat.define_singleton_method(:add_message) { |_| nil }
          chat.define_singleton_method(:with_schema) { |_| self }
          chat.define_singleton_method(:complete) { raise RubyLLM::ServerError, "primary down" }
          chat
        else
          stubbed_chat("fallback-ok")
        end
      end

      workflow = with_stubbed_class("SpecBlockFallbackWorkflow", workflow_class) do
        initial_state :idle; state :done; state :failed
        transition :go, from: :idle, to: :done do
          execute :spec_block_fallback
          on_failure :fail
        end
      end.new(context: { primary: "gpt-5.5" })

      workflow.run!

      expect(models_tried).to eq(%w[gpt-5.5 gpt-5-mini])
    end
  end

  describe "block return-value validation" do
    it "fails the step with Smith::AgentError when the block returns nil" do
      agent = with_stubbed_class("SpecBlockNilAgent", agent_class) do
        register_as :spec_block_nil
        model { |_ctx| nil }
      end

      allow(agent).to receive(:chat) { stubbed_chat("never reached") }

      workflow = with_stubbed_class("SpecBlockNilWorkflow", workflow_class) do
        initial_state :idle; state :done; state :failed
        transition :go, from: :idle, to: :done do execute :spec_block_nil; on_failure :fail end
      end.new

      result = workflow.run!

      expect(result.state).to eq(:failed)
      expect(result.steps.first[:error]).to be_a(agent_error)
      expect(result.steps.first[:error].message).to match(/non-empty string/)
    end

    it "fails the step with Smith::AgentError when the block returns an empty string" do
      agent = with_stubbed_class("SpecBlockEmptyAgent", agent_class) do
        register_as :spec_block_empty
        model { |_ctx| "" }
      end

      allow(agent).to receive(:chat) { stubbed_chat("never reached") }

      workflow = with_stubbed_class("SpecBlockEmptyWorkflow", workflow_class) do
        initial_state :idle; state :done; state :failed
        transition :go, from: :idle, to: :done do execute :spec_block_empty; on_failure :fail end
      end.new

      result = workflow.run!

      expect(result.state).to eq(:failed)
      expect(result.steps.first[:error]).to be_a(agent_error)
    end

    it "fails the step with Smith::AgentError when the block returns a non-string" do
      agent = with_stubbed_class("SpecBlockNonStringAgent", agent_class) do
        register_as :spec_block_non_string
        model { |_ctx| :gpt_5_5 }
      end

      allow(agent).to receive(:chat) { stubbed_chat("never reached") }

      workflow = with_stubbed_class("SpecBlockNonStringWorkflow", workflow_class) do
        initial_state :idle; state :done; state :failed
        transition :go, from: :idle, to: :done do execute :spec_block_non_string; on_failure :fail end
      end.new

      result = workflow.run!

      expect(result.state).to eq(:failed)
      expect(result.steps.first[:error]).to be_a(agent_error)
    end
  end

  describe "inheritance" do
    it "subclasses inherit the parent's model_block" do
      parent = with_stubbed_class("SpecBlockInheritParentAgent", agent_class) do
        model { |_ctx| "gpt-5.5" }
      end
      child = Class.new(parent)

      expect(child.model_block).to eq(parent.model_block)
    end

    it "subclasses can redeclare with a static model, clearing the inherited block" do
      parent = with_stubbed_class("SpecBlockInheritOverrideAgent", agent_class) do
        model { |_ctx| "gpt-5.5" }
      end
      child = Class.new(parent)
      child.model "claude-opus-4-7"

      expect(child.model_block).to be_nil
      expect(child.chat_kwargs[:model]).to eq("claude-opus-4-7")
    end
  end
end
