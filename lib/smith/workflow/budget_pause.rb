# frozen_string_literal: true

module Smith
  class Workflow
    # A tool loop that pauses for budget. A step whose `retry_on` names
    # BudgetUnavailable (or an ancestor), on an attempt it may retry, holds
    # every round of its call's tool loop on the host's budget ledger, not
    # only the first. When the ledger refuses a later round, the step's
    # tools have run: the refusal carries the messages the call added (its
    # tool calls and their results, Budget::Continuation), the step's tool
    # guard lets it through, and the retry (durable: a wait the host ends
    # once there is budget, its continuation kept with the pending retry)
    # continues the loop from them, running none of its tools again. A step
    # that cannot retry for budget lets a later round go on, unheld, and
    # reconciles what it spent. Only a serial agent step pauses so.
    module BudgetPause
      private

      def start_budget_pause(transition)
        @budget_pause_attempts = budget_pause_attempts(transition)
        pending = @pending_retry
        @budget_continuation = (pending["continuation"] if pending && pending["transition"] == transition.name.to_s)
      end

      def budget_pause_attempts(transition)
        config = transition.retry_config
        return unless config && serial_agent_step?(transition)

        config.fetch(:attempts) if config.fetch(:error_classes).any? { _1 >= BudgetUnavailable }
      end

      def serial_agent_step?(transition)
        !transition.agent_name.nil? && !transition.parallel? && !transition.fanout? && !transition.optimized? &&
          !transition.orchestrated?
      end

      def budget_pausable? = !@budget_pause_attempts.nil? && @step_attempt.to_i < @budget_pause_attempts

      def keep_budget_continuation(error)
        @budget_continuation = error.continuation if own_pause?(error)
      end

      # A tool loop this run's own step paused, which its retry continues
      # from its tools' results. One a nested workflow paused is not: the
      # retry starts the child over, and its tools run again.
      def own_pause?(error)
        error.is_a?(BudgetUnavailable) && !error.continuation.nil? && error.paused_by.equal?(self)
      end

      # The paused loop's messages, after the attempt's prepared input.
      def continue_paused_loop(chat)
        return unless @budget_continuation

        Budget::Continuation.load(@budget_continuation).each { chat.add_message(_1) }
      end
    end
  end
end
