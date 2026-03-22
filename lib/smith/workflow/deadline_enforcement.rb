# frozen_string_literal: true

require "time"

module Smith
  class Workflow
    module DeadlineEnforcement
      private

      def check_deadline!
        deadline = effective_deadline
        return unless deadline

        raise DeadlineExceeded, "wall_clock deadline exceeded" if Time.now.utc >= deadline
      end

      def effective_deadline
        call_dl = Thread.current[:smith_call_deadline]
        [wall_clock_deadline, call_dl].compact.min
      end

      def with_agent_context(agent_class)
        saved_deadline = Tool.current_deadline
        saved_call_ledger = Thread.current[:smith_call_ledger]
        apply_agent_deadline(agent_class)
        narrow_tool_deadline!
        apply_agent_tool_calls(agent_class)
        apply_agent_call_ledger(agent_class)
        yield
      ensure
        Tool.current_deadline = saved_deadline
        Thread.current[:smith_call_ledger] = saved_call_ledger
        clear_agent_deadline
        clear_agent_tool_calls
      end

      def effective_call_ledger
        @ledger || Thread.current[:smith_call_ledger]
      end

      def apply_agent_deadline(agent_class)
        agent_wc = agent_class&.budget&.dig(:wall_clock)
        Thread.current[:smith_call_deadline] = agent_wc ? Time.now.utc + agent_wc : nil
      end

      def clear_agent_deadline
        Thread.current[:smith_call_deadline] = nil
      end

      def narrow_tool_deadline!
        call_dl = Thread.current[:smith_call_deadline]
        return unless call_dl

        current = Tool.current_deadline
        Tool.current_deadline = current ? [current, call_dl].min : call_dl
      end

      def apply_agent_tool_calls(agent_class)
        agent_tc = agent_class&.budget&.dig(:tool_calls)
        Tool.current_tool_call_allowance = agent_tc ? { remaining: agent_tc } : nil
      end

      def clear_agent_tool_calls
        Tool.current_tool_call_allowance = nil
      end

      def apply_agent_call_ledger(agent_class)
        Thread.current[:smith_call_ledger] = @ledger ? nil : build_agent_call_ledger(agent_class)
      end

      def build_agent_call_ledger(agent_class)
        agent_budget = agent_class&.budget
        return nil unless agent_budget

        limits = {}
        limits[:token_limit] = agent_budget[:token_limit] if agent_budget[:token_limit]
        limits[:total_cost] = agent_budget[:cost] if agent_budget[:cost]
        return nil if limits.empty?

        Budget::Ledger.new(limits: limits)
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
