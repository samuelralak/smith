# frozen_string_literal: true

module Smith
  class Context
    module ObservationMasking
      SYSTEM_ROLES = %i[system].push("system").freeze

      def self.apply(messages, strategy:)
        return messages unless strategy

        window = strategy[:window]
        return messages unless window

        system_msgs, non_system = messages.partition { |m| SYSTEM_ROLES.include?(m[:role]) }
        system_msgs + non_system.last(window)
      end
    end
  end
end
