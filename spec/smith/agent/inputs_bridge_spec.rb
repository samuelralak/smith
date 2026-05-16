# frozen_string_literal: true

# Workflow @context → agent inputs bridge. Lets block-form RubyLLM DSLs
# (tools, instructions, params, headers, schema) access workflow-context
# data via `runtime_context.<input_name>` — without requiring callers
# to pass the same data twice through chat() kwargs.
#
# The bridge fires from `Smith::Agent::Lifecycle#attempt_model`. Only
# declared `inputs` are bridged; absent / non-Hash @context short-circuits
# cleanly. Static-form agents (no `inputs` declaration) are unaffected
# (declared list is empty → empty bridge → no behavioral change).
RSpec.describe "Smith::Agent::Lifecycle workflow-input bridge" do
  let(:agent_class) { require_const("Smith::Agent") }
  let(:workflow_class) { require_const("Smith::Workflow") }

  def stubbed_chat(content, input_tokens: 5, output_tokens: 3)
    chat = Object.new
    chat.define_singleton_method(:add_message) { |_| nil }
    chat.define_singleton_method(:with_schema) { |_| self }
    chat.define_singleton_method(:complete) do
      Struct.new(:content, :input_tokens, :output_tokens).new(content, input_tokens, output_tokens)
    end
    chat
  end

  it "bridges declared inputs from workflow @context to agent.chat kwargs" do
    agent = with_stubbed_class("SpecBridgeDeclaredAgent", agent_class) do
      register_as :spec_bridge_declared
      model "gpt-5-mini"
      inputs :form_kind, :tone
    end

    captured = []
    allow(agent).to receive(:chat) do |**kwargs|
      captured << kwargs
      stubbed_chat("ok")
    end

    workflow = with_stubbed_class("SpecBridgeDeclaredWorkflow", workflow_class) do
      initial_state :idle; state :done
      transition :go, from: :idle, to: :done do execute :spec_bridge_declared end
    end.new(context: { form_kind: "article", tone: "professional", unrelated: "ignored" })

    workflow.run!

    expect(captured.first).to include(model: "gpt-5-mini", form_kind: "article", tone: "professional")
    expect(captured.first).not_to include(:unrelated)
  end

  it "is a no-op for agents without declared inputs (no behavioral change for static-form agents)" do
    agent = with_stubbed_class("SpecBridgeNoInputsAgent", agent_class) do
      register_as :spec_bridge_no_inputs
      model "gpt-5-mini"
      # no `inputs` declaration
    end

    captured = []
    allow(agent).to receive(:chat) do |**kwargs|
      captured << kwargs
      stubbed_chat("ok")
    end

    workflow = with_stubbed_class("SpecBridgeNoInputsWorkflow", workflow_class) do
      initial_state :idle; state :done
      transition :go, from: :idle, to: :done do execute :spec_bridge_no_inputs end
    end.new(context: { form_kind: "article", anything: "else" })

    workflow.run!

    # chat is called with only model — declared inputs is empty so no kwargs added
    expect(captured.first.keys).to eq([:model])
  end

  it "passes nil for declared inputs that are absent from @context (declaration = contract)" do
    # Declaration `inputs :tone` promises the agent's runtime_context exposes
    # `tone` as a callable singleton method — REGARDLESS of @context content.
    # Skipping absent inputs would force every agent block to check
    # `respond_to?(:tone)` defensively before reading. Passing nil instead
    # mirrors the silent-nil semantics agent authors already get from
    # `ctx[:tone]` in the Smith-owned model block, and matches the principle
    # that nil is a valid value for a declared-but-unset input.
    agent = with_stubbed_class("SpecBridgeAbsentAgent", agent_class) do
      register_as :spec_bridge_absent
      model "gpt-5-mini"
      inputs :form_kind, :tone
    end

    captured = []
    allow(agent).to receive(:chat) do |**kwargs|
      captured << kwargs
      stubbed_chat("ok")
    end

    workflow = with_stubbed_class("SpecBridgeAbsentWorkflow", workflow_class) do
      initial_state :idle; state :done
      transition :go, from: :idle, to: :done do execute :spec_bridge_absent end
    end.new(context: { form_kind: "article" }) # tone absent

    workflow.run!

    expect(captured.first).to include(form_kind: "article", tone: nil)
  end

  # Reserved input names are auto-injected by Smith::Agent.chat from the
  # resolved profile (Smith::Models::Normalizer fills runtime_context for
  # block-form DSLs branching on the active model). They must coexist with
  # user-declared inputs: the getter returns reserved ∪ user, the setter
  # MERGES (not replaces) reserved names so a subclass calling `inputs :foo`
  # doesn't lose RESERVED_INPUT_NAMES. RubyLLM's bare `@input_names = names`
  # (agent.rb:96) replaces, which is why Smith overrides both forms.
  describe "RESERVED_INPUT_NAMES merge + collision contract" do
    it "exposes RESERVED_INPUT_NAMES via the no-arg getter on a bare agent" do
      bare_agent = with_stubbed_class("SpecBridgeBareAgent", agent_class) do
        register_as :spec_bridge_bare
        model "gpt-5-mini"
        # no user `inputs` declared
      end

      reserved = Smith::Agent::RESERVED_INPUT_NAMES
      expect(bare_agent.inputs).to match_array(reserved)
      expect(bare_agent.inputs).to be_frozen
    end

    it "MERGES reserved names with user-declared inputs (does not replace)" do
      merged_agent = with_stubbed_class("SpecBridgeMergedAgent", agent_class) do
        register_as :spec_bridge_merged
        model "gpt-5-mini"
        inputs :form_kind, :tone
      end

      reserved = Smith::Agent::RESERVED_INPUT_NAMES
      expect(merged_agent.inputs).to include(*reserved, :form_kind, :tone)
      expect(merged_agent.inputs).to be_frozen
    end

    it "deduplicates if the user accidentally re-declares with the same name twice" do
      dedup_agent = with_stubbed_class("SpecBridgeDedupAgent", agent_class) do
        register_as :spec_bridge_dedup
        model "gpt-5-mini"
        inputs :form_kind, :form_kind, :tone
      end

      form_kind_count = dedup_agent.inputs.count { |n| n == :form_kind }
      expect(form_kind_count).to eq(1)
    end

    it "raises Smith::AgentError when a user-declared name collides with :model_id" do
      expect {
        with_stubbed_class("SpecBridgeCollidesModelId", agent_class) do
          register_as :spec_bridge_collides_model_id
          model "gpt-5-mini"
          inputs :model_id
        end
      }.to raise_error(Smith::AgentError, /model_id.*reserved by Smith/)
    end

    it "raises Smith::AgentError when a user-declared name collides with :provider" do
      expect {
        with_stubbed_class("SpecBridgeCollidesProvider", agent_class) do
          register_as :spec_bridge_collides_provider
          model "gpt-5-mini"
          inputs :provider
        end
      }.to raise_error(Smith::AgentError, /provider.*reserved by Smith/)
    end

    it "raises Smith::AgentError when a user-declared name collides with :endpoint_mode" do
      expect {
        with_stubbed_class("SpecBridgeCollidesEndpointMode", agent_class) do
          register_as :spec_bridge_collides_endpoint_mode
          model "gpt-5-mini"
          inputs :endpoint_mode
        end
      }.to raise_error(Smith::AgentError, /endpoint_mode.*reserved by Smith/)
    end

    it "reports all colliding names at once when multiple reserved + benign are mixed" do
      expect {
        with_stubbed_class("SpecBridgeCollidesMultiple", agent_class) do
          register_as :spec_bridge_collides_multiple
          model "gpt-5-mini"
          inputs :form_kind, :model_id, :provider, :tone
        end
      }.to raise_error(Smith::AgentError) do |err|
        expect(err.message).to match(/model_id/)
        expect(err.message).to match(/provider/)
      end
    end

    it "bridge slices to USER-DECLARED inputs only, so stale @context values for reserved names never leak through" do
      # The bridge at Lifecycle#bridge_workflow_inputs slices @context to
      # user-declared inputs only and explicitly excludes RESERVED_INPUT_NAMES.
      # If the bridge passed reserved names from @context, a stale value
      # there could override the profile-resolved value that Smith::Agent.chat
      # injects from Models::Profile mid-attempt. This test pins that the
      # bridge's kwargs contain user-declared inputs only, never reserved
      # names sourced from @context.
      agent = with_stubbed_class("SpecBridgeReservedSkipAgent", agent_class) do
        register_as :spec_bridge_reserved_skip
        model "gpt-5-mini"
        inputs :form_kind
      end

      captured = []
      allow(agent).to receive(:chat) do |**kwargs|
        captured << kwargs
        stubbed_chat("ok")
      end

      workflow = with_stubbed_class("SpecBridgeReservedSkipWorkflow", workflow_class) do
        initial_state :idle; state :done
        transition :go, from: :idle, to: :done do execute :spec_bridge_reserved_skip end
      end.new(context: { form_kind: "article", model_id: "stale-value", provider: "stale-provider", endpoint_mode: "stale-mode" })

      workflow.run!

      # form_kind reaches the agent via the bridge.
      expect(captured.first).to include(form_kind: "article")
      # Stale @context values for RESERVED_INPUT_NAMES are NEVER bridged.
      # Smith::Agent.chat's reserved-injection path (which the spy bypasses)
      # is the only source of model_id/provider/endpoint_mode; the bridge
      # MUST NOT supply them from @context.
      expect(captured.first).not_to have_key(:model_id)
      expect(captured.first).not_to have_key(:provider)
      expect(captured.first).not_to have_key(:endpoint_mode)
    end
  end
end
