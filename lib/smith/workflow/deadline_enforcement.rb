# frozen_string_literal: true

require "time"

module Smith
  class Workflow
    module DeadlineEnforcement
      private

      def check_deadline!
        deadline = wall_clock_deadline
        return unless deadline

        raise DeadlineExceeded, "wall_clock deadline exceeded" if Time.now.utc >= deadline
      end

      def wall_clock_deadline
        return @wall_clock_deadline if defined?(@wall_clock_deadline)

        limit = self.class.budget&.dig(:wall_clock)
        @wall_clock_deadline = limit ? Time.iso8601(@created_at) + limit : nil
      end
    end
  end
end
