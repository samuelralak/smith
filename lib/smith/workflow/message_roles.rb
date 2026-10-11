# frozen_string_literal: true

module Smith
  class Workflow
    # The roles a session message may carry, matched exactly. A host admits
    # user, assistant and tool messages; system messages come only from
    # Smith (injected state) and the host's `seed_messages` builder.
    module MessageRoles
      ALL = %w[system user assistant tool].freeze
      ADMITTED = %w[user assistant tool].freeze

      module_function

      # The role of a message Hash with String or Symbol keys, when it is
      # one of `allowed`; nil otherwise.
      def role(message, allowed = ALL)
        return unless message.is_a?(Hash)

        value = message.key?(:role) ? message[:role] : message["role"]
        value = value.to_s if value.is_a?(Symbol)
        value if value.is_a?(String) && allowed.include?(value)
      end
    end
  end
end
