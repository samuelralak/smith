# frozen_string_literal: true

# Pins Smith's normalization of RubyLLM's block-form attribute setters.
#
# RubyLLM evaluates these blocks via `runtime.instance_exec(&block)`, which
# sets `self` to runtime_context but passes NO positional arguments.
# Smith's `model do |ctx|` block-form (Smith-owned) uses `block.call(@context)`
# explicitly. Without normalization, agent authors would face inconsistent
# DSLs: `|ctx|` works for `model` but silently binds nil for `tools`.
#
# Smith wraps blocks with arity != 0 so `|ctx|` receives the runtime AND
# `self` is still the runtime — both `ctx.x` and bare `x` work. Zero-arity
# blocks pass through unchanged (preserving RubyLLM's documented bare-method
# convention).
RSpec.describe "Smith::Agent runtime-block DSL normalization" do
  let(:agent_class) { require_const("Smith::Agent") }

  def runtime_with(form_kind:)
    runtime = Object.new
    runtime.define_singleton_method(:form_kind) { form_kind }
    runtime
  end

  describe "tools block-form" do
    it "supports |ctx| — receives runtime as positional arg" do
      agent = with_stubbed_class("SpecToolsCtxArg", agent_class) do
        tools { |ctx| ctx.form_kind == "article" ? [:think] : [] }
      end

      runtime = runtime_with(form_kind: "article")
      result = runtime.instance_exec(&agent.tools)
      expect(result).to eq([:think])
    end

    it "supports zero-arity bare-method (RubyLLM idiom) — self is runtime" do
      agent = with_stubbed_class("SpecToolsBare", agent_class) do
        tools { form_kind == "article" ? [:think] : [] }
      end

      runtime = runtime_with(form_kind: "article")
      result = runtime.instance_exec(&agent.tools)
      expect(result).to eq([:think])
    end

    it "exposes runtime via BOTH self AND |ctx| inside the wrapped block" do
      # Authors can mix styles: read inputs as `ctx.x` for explicitness AND
      # use bare method calls for chat/prompt helpers — both dispatch to
      # the runtime context.
      agent = with_stubbed_class("SpecToolsMixed", agent_class) do
        tools do |ctx|
          via_arg  = ctx.form_kind
          via_self = form_kind
          [via_arg, via_self]
        end
      end

      runtime = runtime_with(form_kind: "article")
      result = runtime.instance_exec(&agent.tools)
      expect(result).to eq(["article", "article"])
    end

    it "passes nil for absent declared inputs (matches Smith's bridge contract)" do
      agent = with_stubbed_class("SpecToolsAbsent", agent_class) do
        tools { |ctx| ctx.form_kind == "article" ? [:think] : [] }
      end

      runtime = runtime_with(form_kind: nil)
      result = runtime.instance_exec(&agent.tools)
      expect(result).to eq([])
    end
  end

  describe "chat() input contract closure" do
    # When a caller invokes `Agent.chat(...)` directly (outside the workflow
    # bridge), Smith fills in nil for any declared inputs that the caller
    # didn't pass. This makes `inputs :form_kind` a uniform contract: agent
    # blocks can read `ctx.form_kind` at every entry point without defensive
    # `respond_to?` checks.
    it "exposes declared user inputs as runtime methods even when caller omits them" do
      agent = with_stubbed_class("SpecChatContract", agent_class) do
        register_as :spec_chat_contract
        model "gpt-5-mini"
        inputs :form_kind, :tone
        tools { |ctx| [ctx.form_kind, ctx.tone] }
      end

      captured_input_values = nil
      allow(agent).to receive(:apply_configuration) do |chat, input_values:, persist_instructions:|
        captured_input_values = input_values
      end
      allow(RubyLLM).to receive(:chat).and_return(Object.new)

      agent.chat(model: "override")

      # User-declared inputs default to nil when caller omits them.
      # Reserved inputs (model_id, provider, endpoint_mode) are also
      # auto-injected by Smith::Agent.chat; assert via `include` rather
      # than `eq` so the reserved-name fill doesn't conflict with this
      # spec's intent (which is the user-declared-input contract).
      expect(captured_input_values).to include(form_kind: nil, tone: nil)
    end

    it "preserves explicitly-passed user input values" do
      agent = with_stubbed_class("SpecChatContractMixed", agent_class) do
        register_as :spec_chat_contract_mixed
        model "gpt-5-mini"
        inputs :form_kind, :tone
      end

      captured_input_values = nil
      allow(agent).to receive(:apply_configuration) do |chat, input_values:, persist_instructions:|
        captured_input_values = input_values
      end
      allow(RubyLLM).to receive(:chat).and_return(Object.new)

      agent.chat(form_kind: "article")

      expect(captured_input_values).to include(form_kind: "article", tone: nil)
    end
  end

  describe "params, headers, schema block-forms" do
    it "params |ctx| receives runtime" do
      agent = with_stubbed_class("SpecParamsCtx", agent_class) do
        params { |ctx| { fk: ctx.form_kind } }
      end
      runtime = runtime_with(form_kind: "article")
      expect(runtime.instance_exec(&agent.params)).to eq({ fk: "article" })
    end

    it "headers |ctx| receives runtime" do
      agent = with_stubbed_class("SpecHeadersCtx", agent_class) do
        headers { |ctx| { "X-Form" => ctx.form_kind } }
      end
      runtime = runtime_with(form_kind: "thread")
      expect(runtime.instance_exec(&agent.headers)).to eq({ "X-Form" => "thread" })
    end

    it "schema |ctx| receives runtime" do
      agent = with_stubbed_class("SpecSchemaCtx", agent_class) do
        schema { |ctx| { read_form: ctx.form_kind } }
      end
      runtime = runtime_with(form_kind: "single_post")
      expect(runtime.instance_exec(&agent.schema)).to eq({ read_form: "single_post" })
    end
  end
end
