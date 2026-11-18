# frozen_string_literal: true

module Smith
  class Agent
    # Which prompt cache an agent's requests ask for beyond the parts a host
    # marks (`cache: true`):
    #
    #   prompt_cache :automatic   # Anthropic caches each request's longest prefix
    #   prompt_cache :none        # the default
    #
    # `:automatic` puts a top-level cache_control on each Anthropic request:
    # Anthropic places the breakpoint on the request's last block and moves
    # it forward as a tool loop grows, so each request reads the one before
    # it from the cache. It counts as one of a request's four breakpoints;
    # any other provider is asked nothing (ProviderRequest).
    module PromptCache
      UNSET = Object.new.freeze
      MODES = %i[none automatic].freeze
      private_constant :UNSET, :MODES

      def prompt_cache(mode = UNSET)
        return @prompt_cache || :none if mode.equal?(UNSET)

        chosen = mode.respond_to?(:to_sym) ? mode.to_sym : mode
        raise ArgumentError, "prompt_cache must be :none or :automatic" unless MODES.include?(chosen)

        @prompt_cache = chosen
      end
    end
  end
end
