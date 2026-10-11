# frozen_string_literal: true

require "json"

module Smith
  class Agent
    # Accepting an agent's response as its output. A refused response takes
    # the agent's refusal fallback once or raises OutputRefused; a cut-off
    # one is retried once with a larger output limit or raises
    # OutputTruncated (unless the agent accepts it); a structured output
    # that is not a JSON object, breaks a schema constraint or fails the
    # agent's output contract is sent back for repair up to the agent's
    # `output_repairs`, then raises OutputInvalid. Every response is
    # billed; one that is set aside settles into the budget with the
    # invocation's failed attempts.
    module OutputIntegrity
      REPAIR_NOTE = "Your previous reply could not be used as the required output:\n%s\n" \
                    "Reply again with output that fixes these problems."
      private_constant :REPAIR_NOTE

      # What one invocation has tried so far.
      Plan = Struct.new(:agent_class, :input, :output_schema, :json_schema, :repairs_left, :retried, :fell_back)
      private_constant :Plan

      private

      def output_plan(agent_class, prepared_input, output_schema)
        Plan.new(agent_class:, input: prepared_input, output_schema:, repairs_left: agent_class.output_repairs,
                 json_schema: output_schema && Providers::SchemaConstraints.json_schema(output_schema))
      end

      # nil when the output is accepted; otherwise a callable that makes the
      # next attempt. Raises when nothing is left to try.
      def output_follow_up(plan, attempt, result)
        case Providers::StopReason.classify(attempt.completion.response_facts[:stop_reason])
        when :refused then return refusal_follow_up(plan, attempt, result)
        when :truncated then return truncation_follow_up(plan, attempt, result) unless accepts_truncation?(plan)
        end

        parse_structured_output!(plan, result)
        problems = output_problems(plan, result.content)
        repair_follow_up(plan, attempt, result, problems) unless problems.empty?
      end

      # A structured output that reached Smith as JSON text (its schema
      # parsing bypassed) is read as RubyLLM reads a schema response.
      def parse_structured_output!(plan, result)
        return unless plan.output_schema && result.content.is_a?(String)

        parsed = JSON.parse(result.content)
        result.content = parsed if parsed.is_a?(Hash)
      rescue JSON::ParserError
        nil
      end

      def accepts_truncation?(plan) = plan.agent_class.on_truncation[:policy] == :accept

      def refusal_follow_up(plan, attempt, result)
        fallback = plan.agent_class.on_refusal[:model]
        if fallback && !plan.fell_back && !fallback.same_candidate?(attempt.model_reference)
          plan.fell_back = true
          return -> { follow_up_attempt(plan, attempt, fallback) }
        end

        raise output_failure(OutputRefused, plan, attempt, result)
      end

      def truncation_follow_up(plan, attempt, result)
        setting = plan.agent_class.on_truncation
        unless setting[:policy] == :retry && !plan.retried && Providers::OutputLimit.supported?(attempt.model_reference.provider)
          raise output_failure(OutputTruncated, plan, attempt, result)
        end

        plan.retried = true
        -> { follow_up_attempt(plan, attempt, attempt.model_reference, output_limit: setting[:max_tokens]) }
      end

      def repair_follow_up(plan, attempt, result, problems)
        raise output_failure(OutputInvalid, plan, attempt, result, problems) unless plan.repairs_left.positive?

        plan.repairs_left -= 1
        plan.input = repair_input(plan.input, result.content, problems)
        -> { follow_up_attempt(plan, attempt, attempt.model_reference) }
      end

      def output_problems(plan, content)
        contract = plan.agent_class.output_contract
        return [] unless plan.output_schema || contract
        return ["/: is not a JSON object"] unless content.is_a?(Hash)

        schema = plan.json_schema && Providers::SchemaConstraints.problems(plan.json_schema["schema"], content)
        Array(schema) + contract_problems(contract, content)
      end

      def contract_problems(contract, content)
        return [] unless contract

        verdict = contract.call(content)
        return [] if verdict.success?

        errors = verdict.errors
        error_lines(errors.respond_to?(:to_h) ? errors.to_h : { nil => [errors.to_s] })
      end

      # { fields: { title: ["is missing"] } } becomes "/fields/title: is missing".
      def error_lines(errors, path = "")
        errors.flat_map do |key, messages|
          at = key.nil? ? path : "#{path}/#{key}"
          next error_lines(messages, at) if messages.is_a?(Hash)

          Array(messages).map { |message| "#{at.empty? ? "/" : at}: #{message}" }
        end.first(OutputFailure::MAX_PROBLEMS)
      end

      def repair_input(input, content, problems)
        rejected = content.is_a?(String) ? content : JSON.generate(content)
        note = format(REPAIR_NOTE, problems.map { |problem| "- #{problem}" }.join("\n"))
        messages = Array(input)
        return messages + [{ role: :assistant, content: rejected }, { role: :user, content: note }] if messages.any?

        [{ role: :user, content: "Your previous reply was:\n#{rejected}\n\n#{note}" }]
      rescue JSON::GeneratorError
        repair_input(input, content.to_s, problems)
      end

      def follow_up_attempt(plan, previous, model_reference, output_limit: nil)
        shape = ProviderRequest::Shape.new(output_schema: plan.output_schema, output_limit:)
        attempt = attempt_model(plan.agent_class, plan.input, model_reference,
                                shape:, attempt_index: previous.attempt_index.to_i + 1)
        return attempt if attempt.success?

        handle_provider_failure!(attempt.error, attempt.model_reference, plan.agent_class,
                                 fallback_available: false, attempt_id: attempt.attempt_id)
      end

      # A billed response that is not the invocation's output settles with
      # its failed attempts.
      def settle_rejected(agent_result)
        (Thread.current[:smith_failed_agent_results] ||= []) << agent_result
        Thread.current[:smith_last_agent_result] = nil
      end

      def output_failure(error_class, plan, attempt, result, problems = [])
        error_class.new(agent_name: plan.agent_class.register_as, model_used: result.model_used,
                        stop_reason: attempt.completion.response_facts[:stop_reason], problems:)
      end
    end
  end
end
