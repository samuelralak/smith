# frozen_string_literal: true

module Smith
  class Tool < RubyLLM::Tool
    # What a tool class declares about itself (`capabilities do ... end`,
    # CapabilityBuilder), read for its privilege check, its traces'
    # sensitivity and whether a step may run it again. A subclass inherits
    # its parent's, key by key: its own block sets or replaces only the keys
    # it names, so a subclass is never less guarded than its parent unless
    # it says so. `replay` alone is not inherited: whether a tool is safe to
    # run again is a fact about its own `perform`, so a subclass is
    # replay-safe only when it declares `replay :safe` itself.
    module CapabilityDeclaration
      NOT_INHERITED = %i[replay].freeze
      private_constant :NOT_INHERITED

      def capabilities(&)
        return inherited_capabilities unless block_given?

        builder = CapabilityBuilder.new
        builder.instance_eval(&)
        @capabilities = builder.to_h.freeze
      end

      # Whether this class itself declares `capabilities { replay :safe }`.
      def replay_safe? = capabilities&.dig(:replay) == :safe

      private

      def inherited_capabilities
        inherited = parent_capabilities
        own = @capabilities if instance_variable_defined?(:@capabilities)
        return own unless inherited

        own ? inherited.merge(own) : inherited
      end

      # The parent's capabilities this class takes (all but `replay`), or nil.
      def parent_capabilities
        inherited = parent_tool&.capabilities&.except(*NOT_INHERITED)
        inherited if inherited&.any?
      end
    end
  end
end
