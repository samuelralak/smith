# frozen_string_literal: true

require "dry-initializer"

module Smith
  module Models
    # Per-chat-construction request shaper. Mutates a RubyLLM::Chat
    # in place to fit the resolved model's capability profile, using
    # RubyLLM's public `with_*` API where it covers the case and
    # scoped instance-variable nulling where no public API exists
    # (RubyLLM has no `without_temperature` / `without_thinking`).
    #
    # Lifetime: built fresh inside Smith::Agent.chat per construction.
    # Never crosses threads. Never cached.
    #
    # Runs OUTSIDE any workflow context — does NOT access:
    #   - Smith.scoped_artifacts (thread-local, set only inside workflows)
    #   - Tool.current_ledger / Tool.current_tool_result_collector
    #   - Thread.current[:smith_last_agent_result]
    # Smith::Trace.record is the ONLY observability surface the normalizer
    # touches; it's safe outside workflow scope.
    class Normalizer
      extend Dry::Initializer

      # Decision record emitted as a :normalizer_decision trace event.
      # The Decision.kind value space is exhaustively documented in the
      # plan; adding a new kind requires updating the trace CONFIG_MAP.
      Decision = Data.define(:kind, :model_id, :detail)

      # No type predicate on options — Smith's existing Dry::Initializer
      # call sites trust internal callers and don't enforce option types.
      option :chat
      option :profile

      # Returns Array<Decision> of mutations performed. The chat is
      # mutated in place; callers usually ignore the return value
      # except in tests.
      def self.apply!(chat, profile:)
        return [] if profile.nil?

        new(chat: chat, profile: profile).apply!
      end

      def apply!
        @decisions = []
        normalize_temperature
        normalize_thinking
        normalize_tools_routing
        emit_trace
        @decisions
      end

      private

      def normalize_temperature
        return if profile.accepts_temperature
        return if chat.instance_variable_get(:@temperature).nil?

        # No public `without_temperature` in RubyLLM 1.15 — direct ivar
        # nulling is the only path. Scoped: only @temperature, only on
        # models that explicitly reject it. Add `RubyLLM::Chat#without_temperature`
        # upstream and Smith retires this line (see UPSTREAM_PROPOSAL.md).
        chat.instance_variable_set(:@temperature, nil)
        @decisions << Decision.new(kind: :temperature_dropped, model_id: profile.model_id, detail: nil)
      end

      def normalize_thinking
        thinking = chat.instance_variable_get(:@thinking)
        return if thinking.nil? || !thinking.enabled?

        case profile.thinking_shape
        when nil
          chat.instance_variable_set(:@thinking, nil)
          @decisions << Decision.new(kind: :thinking_dropped, model_id: profile.model_id, detail: nil)
        when :budget_tokens, :reasoning_effort
          # RubyLLM's provider renderers already emit the right shape.
          # Leave @thinking unchanged.
        when :adaptive
          translate_thinking_to_adaptive(thinking)
        end
      end

      def translate_thinking_to_adaptive(thinking)
        effort = thinking.respond_to?(:effort) && thinking.effort ? thinking.effort : "high"
        merge_params(thinking: { type: "adaptive" }, output_config: { effort: effort })

        # Null @thinking so RubyLLM's render_payload doesn't ALSO emit
        # the budget_tokens shape that would conflict with our adaptive
        # injection at deep_merge time.
        chat.instance_variable_set(:@thinking, nil)
        @decisions << Decision.new(
          kind: :thinking_translated_to_adaptive,
          model_id: profile.model_id,
          detail: { effort: effort }
        )
      end

      def normalize_tools_routing
        # Stubbed chat objects in tests may not implement .tools; gracefully
        # skip rather than crash on respond_to? check.
        return unless chat.respond_to?(:tools)

        tools = chat.tools.values
        return if tools.empty?
        return unless thinking_active?

        return if profile.tools_with_thinking_native

        if profile.tools_with_thinking_route == :responses &&
           Smith.config.openai_api_mode == :auto
          merge_params(openai_api_mode: :responses)
          @decisions << Decision.new(kind: :routed_via_responses, model_id: profile.model_id, detail: nil)
          return
        end

        drop_incompatible_tools(tools)
      end

      def thinking_active?
        thinking = chat.instance_variable_get(:@thinking)
        return true if thinking&.enabled?

        # Also active if we already translated to adaptive (in which case
        # @thinking is nil but params carry the thinking spec).
        params = chat.instance_variable_get(:@params) || {}
        params.key?(:thinking) || params.key?(:reasoning) || params.key?(:reasoning_effort)
      end

      def drop_incompatible_tools(tools)
        effective_endpoint = effective_endpoint_for_compatibility
        incompatible = tools.reject do |tool|
          spec = tool.class.respond_to?(:compatible_with_spec) ? tool.class.compatible_with_spec : nil
          if defined?(Smith::Tool::Compatibility)
            Smith::Tool::Compatibility.allows?(spec, profile, effective_endpoint: effective_endpoint)
          else
            true
          end
        end
        return if incompatible.empty?

        retained = tools - incompatible
        chat.with_tools(*retained, replace: true)

        incompatible.each do |tool|
          @decisions << Decision.new(
            kind: :tool_dropped,
            model_id: profile.model_id,
            detail: { tool: tool.class.name }
          )
        end
      end

      # Profile.endpoint_mode reports the INTENDED endpoint (per the
      # inference rule). Smith.config.openai_api_mode policy can downgrade
      # the EFFECTIVE endpoint — e.g., a profile with route :responses
      # actually uses :chat_completions when openai_api_mode is :off.
      # The compatibility check needs the effective endpoint to make
      # the right drop/keep decision.
      def effective_endpoint_for_compatibility
        if profile.tools_with_thinking_route == :responses &&
           Smith.config.openai_api_mode != :auto
          :chat_completions
        else
          profile.endpoint_mode
        end
      end

      # with_params REPLACES @params in RubyLLM (chat.rb:96), so the
      # normalizer always reads existing + merges + writes back to
      # preserve prior user calls to with_params.
      def merge_params(**new_params)
        existing = chat.instance_variable_get(:@params) || {}
        chat.with_params(**existing, **new_params)
      end

      def emit_trace
        return if @decisions.empty?
        return unless defined?(Smith::Trace)

        @decisions.each do |decision|
          Smith::Trace.record(type: :normalizer_decision, data: decision.to_h)
        end
      end
    end
  end
end
