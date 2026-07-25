# frozen_string_literal: true

require "dry-initializer"

require_relative "tool_routing"

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
        ToolRouting.new(
          chat: chat,
          profile: profile,
          decision_recorder: method(:record_decision)
        ).call
      end

      # with_params REPLACES @params in RubyLLM (chat.rb:96), so the
      # normalizer always reads existing + merges + writes back to
      # preserve prior user calls to with_params.
      def merge_params(**new_params)
        existing = chat.instance_variable_get(:@params) || {}
        chat.with_params(**existing, **new_params)
      end

      def record_decision(kind, model_id, detail)
        @decisions << Decision.new(kind: kind, model_id: model_id, detail: detail)
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
