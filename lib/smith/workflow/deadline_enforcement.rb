# frozen_string_literal: true

require "time"

require_relative "thread_context_snapshot"

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

      def with_agent_context(agent_class, &block)
        saved_deadline = Tool.current_deadline
        saved_call_ledger = Thread.current[:smith_call_ledger]
        snapshot = ThreadContextSnapshot.new(
          tool_attributes: %i[current_deadline current_tool_call_allowance current_tool_execution_tracker],
          thread_keys: %i[smith_call_deadline smith_call_ledger],
          scoped_artifacts: false
        )
        snapshot.around do
          apply_agent_context(agent_class)
          Thread.handle_interrupt(Object => :immediate, &block)
        ensure
          restore_agent_context(saved_deadline, saved_call_ledger)
        end
      end

      def apply_agent_context(agent_class)
        apply_agent_deadline(agent_class)
        narrow_tool_deadline!
        apply_agent_tool_calls(agent_class)
        Tool.current_tool_execution_tracker ||= Tool::ExecutionTracker.new
        apply_agent_call_ledger(agent_class)
      end

      def restore_agent_context(deadline, call_ledger)
        Tool.current_deadline = deadline
        Thread.current[:smith_call_ledger] = call_ledger
        clear_agent_deadline
        clear_agent_tool_calls
        Tool.current_tool_execution_tracker = nil
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
        if agent_class&.tool_budget_exhaustion == :complete && agent_tc.nil?
          raise AgentError, "tool_budget_exhaustion :complete requires a finite tool_calls budget"
        end

        Tool.current_tool_call_allowance = build_agent_tool_call_allowance(agent_class, agent_tc)
      end

      def build_agent_tool_call_allowance(agent_class, agent_tool_calls)
        return unless agent_tool_calls

        parent = Tool.current_tool_call_allowance
        if parent && !parent.is_a?(Tool::CallAllowance)
          raise AgentError, "agent tool_calls budgets cannot scope a legacy Hash tool call allowance"
        end
        return parent.scope(agent_tool_calls, on_exhaustion: agent_class.tool_budget_exhaustion) if parent

        Tool::CallAllowance.new(agent_tool_calls, on_exhaustion: agent_class.tool_budget_exhaustion)
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
