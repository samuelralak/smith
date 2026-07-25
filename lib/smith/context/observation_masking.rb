# frozen_string_literal: true

module Smith
  class Context
    module ObservationMasking
      SYSTEM_ROLES = %i[system].push("system").freeze

      def self.apply(messages, strategy:, seed_message_count: 0)
        return messages unless strategy

        window = strategy[:window]
        return messages unless window

        prefix_count = strategy[:preserve_seed] == true ? seed_message_count : 0
        prefix = messages.first(prefix_count)
        dynamic_messages = messages.drop(prefix_count)

        prefix + system_messages(dynamic_messages) + recent_observations(dynamic_messages, window)
      end

      def self.system_message?(message)
        SYSTEM_ROLES.include?(message[:role] || message["role"])
      end

      def self.system_messages(messages)
        messages.select { |message| system_message?(message) }
      end

      def self.recent_observations(messages, window)
        raise ArgumentError, "negative array size" if window.negative?
        return [] if window.zero?

        selected = []
        messages.reverse_each do |message|
          next if system_message?(message)

          selected << message
          break if selected.length == window
        end
        selected.reverse
      end
      private_class_method :system_message?, :system_messages, :recent_observations
    end
  end
end
