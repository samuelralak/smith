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

        @wall_clock_deadline = compute_wall_clock_deadline
      end

      def compute_wall_clock_deadline
        limit = self.class.budget&.dig(:wall_clock)
        own_deadline = limit ? Time.iso8601(@created_at) + limit : nil

        return own_deadline unless @inherited_deadline
        return @inherited_deadline unless own_deadline

        [own_deadline, @inherited_deadline].min
      end
    end
  end
end
