# frozen_string_literal: true

module Smith
  module Models
    # Pattern-based provider capability rules. Library-level knowledge
    # about how PROVIDER FAMILIES shape their API payloads — independent
    # of specific model ids or downstream applications.
    #
    # Smith ships ZERO specific model_id declarations. Each rule matches
    # a regex or version-aware predicate against the resolved model_id
    # at runtime. New model releases that fit existing patterns work
    # automatically (e.g., a future claude-opus-4-9 matches the Opus 4.7+
    # adaptive-thinking rule).
    #
    # Rule order matters: most specific patterns first. Hosts that need
    # to ADD provider knowledge (a new provider Smith doesn't ship rules
    # for, or a custom finetune) can `prepend_rule` at runtime.
    #
    # The rules array is mutable for runtime extension; tests must use
    # the `with_rules(*rules) { ... }` block helper to avoid test-suite
    # leakage of `prepend_rule` mutations.
    module Inference
      # A single rule maps a model_id matcher to capability values.
      # The matcher is a Proc[String -> Boolean] — regex match OR
      # version-aware predicate (e.g., Opus 4.7+).
      Rule = Data.define(
        :provider,
        :matcher,
        :thinking_shape,
        :accepts_temperature,
        :tools_with_thinking_native,
        :tools_with_thinking_route
      ) do
        def matches?(model_id)
          matcher.call(model_id.to_s)
        end

        def to_profile(model_id)
          Profile.new(
            model_id: model_id.to_s,
            provider: provider,
            thinking_shape: thinking_shape,
            accepts_temperature: accepts_temperature,
            tools_with_thinking_native: tools_with_thinking_native,
            tools_with_thinking_route: tools_with_thinking_route
          )
        end
      end

      def self.rules
        @_rules
      end

      def self.prepend_rule(rule)
        rules.unshift(rule)
      end

      def self.reset!
        @_rules = default_rules.dup
      end

      # Block-form test helper. Yields with the given rules INSTEAD of
      # the default set; restores afterward even if the block raises.
      # Prevents test-suite leakage of `prepend_rule` mutations.
      def self.with_rules(*overrides)
        previous = @_rules
        @_rules = overrides.flatten
        yield
      ensure
        @_rules = previous
      end

      def self.profile_for(model_id)
        rule = rules.find { |r| r.matches?(model_id) }
        rule&.to_profile(model_id)
      end

      # Library-shipped pattern rules. Order: most specific first per
      # provider; provider families in declaration order. NO specific
      # model_id strings — only PROVIDER FAMILY and version-range patterns.
      def self.default_rules
        [
          # ----- Anthropic -----

          # Opus 4.7+: adaptive thinking, no temperature accepted.
          Rule.new(
            provider: :anthropic,
            matcher: lambda { |id|
              m = id.match(/\Aclaude-opus-4-(\d+)/)
              m && m[1].to_i >= 7
            },
            thinking_shape: :adaptive,
            accepts_temperature: false,
            tools_with_thinking_native: true,
            tools_with_thinking_route: nil
          ),
          # Opus/Sonnet/Haiku 4.0-4.6: budget_tokens thinking.
          Rule.new(
            provider: :anthropic,
            matcher: lambda { |id|
              m = id.match(/\Aclaude-(?:opus|sonnet|haiku)-4-(\d+)/)
              m && m[1].to_i <= 6
            },
            thinking_shape: :budget_tokens,
            accepts_temperature: true,
            tools_with_thinking_native: true,
            tools_with_thinking_route: nil
          ),
          # Claude 3.7 Sonnet introduced extended thinking via budget_tokens.
          # Claude 3.5 and earlier DON'T have thinking — handled by the
          # safe-default Anthropic rule below.
          Rule.new(
            provider: :anthropic,
            matcher: ->(id) { id.match?(/\Aclaude-3-7/) },
            thinking_shape: :budget_tokens,
            accepts_temperature: true,
            tools_with_thinking_native: true,
            tools_with_thinking_route: nil
          ),
          # Any other Claude (3.5, 3.0, 2.x): safe default — no thinking,
          # accepts temperature, tools work normally on chat-completions.
          Rule.new(
            provider: :anthropic,
            matcher: ->(id) { id.match?(/\Aclaude-/) },
            thinking_shape: nil,
            accepts_temperature: true,
            tools_with_thinking_native: false,
            tools_with_thinking_route: nil
          ),

          # ----- OpenAI -----

          # gpt-5 family + o-series reasoning models: reasoning_effort,
          # no temperature, needs /v1/responses for tools+thinking combo
          # (chat-completions rejects the combination).
          Rule.new(
            provider: :openai,
            matcher: ->(id) { id.match?(/\A(gpt-5|o\d)/) },
            thinking_shape: :reasoning_effort,
            accepts_temperature: false,
            tools_with_thinking_native: false,
            tools_with_thinking_route: :responses
          ),
          # gpt-4.x: no thinking, accepts temperature.
          Rule.new(
            provider: :openai,
            matcher: ->(id) { id.match?(/\Agpt-4/) },
            thinking_shape: nil,
            accepts_temperature: true,
            tools_with_thinking_native: false,
            tools_with_thinking_route: nil
          ),
          # Older OpenAI: no thinking, accepts temperature.
          Rule.new(
            provider: :openai,
            matcher: ->(id) { id.match?(/\A(gpt-3|text-)/) },
            thinking_shape: nil,
            accepts_temperature: true,
            tools_with_thinking_native: false,
            tools_with_thinking_route: nil
          ),

          # ----- Gemini -----

          # Gemini 2.5+ (all variants, including Flash) supports thinking
          # via budget_tokens. Earlier Gemini (1.x, 2.0) does not.
          Rule.new(
            provider: :gemini,
            matcher: lambda { |id|
              m = id.match(/\Agemini-(\d+)\.(\d+)/)
              m && (m[1].to_i > 2 || (m[1].to_i == 2 && m[2].to_i >= 5))
            },
            thinking_shape: :budget_tokens,
            accepts_temperature: true,
            tools_with_thinking_native: true,
            tools_with_thinking_route: nil
          ),
          # Any other Gemini (1.x, 2.0): no thinking.
          Rule.new(
            provider: :gemini,
            matcher: ->(id) { id.match?(/\Agemini-/) },
            thinking_shape: nil,
            accepts_temperature: true,
            tools_with_thinking_native: false,
            tools_with_thinking_route: nil
          )
        ].freeze
      end

      # Eagerly initialized at module load (after default_rules is
      # defined) so concurrent first-callers cannot race the `||=`
      # lazy-init and end up holding references to separate Array
      # instances. Host calls to `prepend_rule` / `reset!` / `with_rules`
      # are still expected to fire only at setup time on the main
      # thread; concurrent mutation after boot is unsupported.
      @_rules = default_rules.dup
    end
  end
end
