# frozen_string_literal: true

module Smith
  class Tool < RubyLLM::Tool
    # What a tool class declares about itself (`capabilities do ... end`,
    # CapabilityBuilder), read for its privilege check, its traces'
    # sensitivity and whether a step may run it again. A subclass inherits
    # its parent's, key by key: its own block sets or replaces only the keys
    # it names, so a subclass is never less guarded than its parent unless
    # it says so.
    module CapabilityDeclaration
      def capabilities(&)
        return inherited_capabilities unless block_given?

        builder = CapabilityBuilder.new
        builder.instance_eval(&)
        @capabilities = builder.to_h.freeze
      end

      # Whether this class, or the nearest that says, declares
      # `capabilities { replay :safe }`; a subclass that does more than its
      # parent declares `replay :unsafe`.
      def replay_safe? = capabilities&.dig(:replay) == :safe

      private

      def inherited_capabilities
        inherited = parent_tool&.capabilities
        own = @capabilities if instance_variable_defined?(:@capabilities)
        return own unless inherited

        own ? inherited.merge(own) : inherited
      end
    end
  end
end
