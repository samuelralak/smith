# frozen_string_literal: true

require "json"

module Smith
  class Agent
    # The follow-up call an output failure may get (OutputIntegrity): a
    # refusal fallback, a truncation retry, or a repair, each within the
    # agent's settings and never once a tool has run in the step, once the
    # call has spent what its step reserved, or past MAX_CALLS calls.
    module OutputRecovery
      MAX_CALLS = 3 + OutputPolicy::MAX_REPAIRS
      REPAIR_NOTE = "Your previous reply could not be used as the required output:\n%s\n" \
                    "Reply again with output that fixes these problems."
      REPAIR_TASK = "Reply with the required output."
      # Why a streamed step's rejected text is withdrawn (Smith::Streaming).
      STREAM_RESETS = { OutputRefused => :fallback, OutputTruncated => :truncation }.freeze
      private_constant :MAX_CALLS, :REPAIR_NOTE, :REPAIR_TASK, :STREAM_RESETS

      private

      def recovery(plan, attempt, result, failure)
        return if tools_ran? || plan.calls >= MAX_CALLS || budget_spent?(result)

        case failure
        when OutputRefused then refusal_recovery(plan, attempt, failure)
        when OutputTruncated then truncation_recovery(plan, attempt, failure)
        else repair_recovery(plan, attempt, result, failure)
        end
      end

      def tools_ran? = Tool.current_tool_execution_tracker&.started? || false

      def refusal_recovery(plan, attempt, failure)
        fallback = plan.agent_class.on_refusal[:model]
        return if fallback.nil? || plan.fell_back || fallback.same_candidate?(attempt.model_reference)

        plan.fell_back = true
        -> { follow_up_attempt(plan, attempt, fallback, failure) }
      end

      def truncation_recovery(plan, attempt, failure)
        limit = retry_limit(plan, attempt)
        return unless limit

        plan.retried = true
        plan.output_limit = limit
        -> { follow_up_attempt(plan, attempt, attempt.model_reference, failure) }
      end

      # The larger limit to retry with, or nil: no retry is declared or left,
      # the provider has no output limit Smith can set, the response ran out
      # of context rather than output, or the limit is not larger than the
      # one the request already had.
      def retry_limit(plan, attempt)
        return unless retry_allowed?(plan, attempt)

        limit = plan.agent_class.on_truncation[:max_tokens]
        current = plan.output_limit || Providers::OutputLimit.current(attempt.model_reference.provider,
                                                                      agent_params(plan.agent_class),
                                                                      attempt.model_reference)
        limit if current.nil? || limit > current
      end

      def retry_allowed?(plan, attempt)
        plan.agent_class.on_truncation[:policy] == :retry && !plan.retried &&
          Providers::OutputLimit.supported?(attempt.model_reference.provider) &&
          stop_reason_of(attempt) != "model_context_window_exceeded"
      end

      def agent_params(agent_class)
        params = agent_class.params if agent_class.respond_to?(:params)
        params.is_a?(Hash) ? params : {}
      end

      def repair_recovery(plan, attempt, result, failure)
        return unless plan.repairs_left.positive?

        plan.repairs_left -= 1
        plan.input = repair_input(plan.input, result.content, failure.problems)
        -> { follow_up_attempt(plan, attempt, attempt.model_reference, failure) }
      end

      # The step's messages as the provider got them (with any continuation
      # turn), the rejected reply as the assistant's, and the problems.
      def repair_input(input, content, problems)
        note = format(REPAIR_NOTE, problems.map { |problem| "- #{problem}" }.join("\n"))
        messages = provider_safe_prepared_input(Array(input))
        messages = [{ role: :user, content: REPAIR_TASK }] if messages.empty?
        messages + [{ role: :assistant, content: rejected_text(content) }, { role: :user, content: note }]
      end

      def rejected_text(content)
        content.is_a?(String) ? content : JSON.generate(content)
      rescue JSON::GeneratorError, Encoding::UndefinedConversionError
        content.to_s
      end

      def follow_up_attempt(plan, previous, model_reference, pending)
        check_deadline!
        plan.calls += 1
        withdraw_streamed(STREAM_RESETS.fetch(pending.class, :repair))
        attempt = attempt_model(plan.agent_class, plan.input, model_reference,
                                shape: plan.shape, attempt_index: previous.attempt_index.to_i + 1)
        return attempt if attempt.success?

        fail_follow_up(plan, attempt, pending)
      end

      def fail_follow_up(plan, attempt, pending)
        account_failed_attempt(attempt.error, attempt.model_reference, plan.agent_class, attempt_id: attempt.attempt_id)
        raise pending, cause: attempt.error
      end

      # Whether the responses so far have reached what the call's step
      # reserved in any budget dimension.
      def budget_spent?(result)
        reservation = Thread.current[:smith_call_reservation]
        return false unless reservation

        spent = extract_actuals([*Array(Thread.current[:smith_failed_agent_results]), result])
        reservation.amounts.any? do |dimension, amount|
          used = Workflow::BudgetIntegration::COST_DIMENSIONS.include?(dimension) ? spent[:cost] : spent[:tokens]
          used >= amount
        end
      end
    end
  end
end
