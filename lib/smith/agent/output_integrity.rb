# frozen_string_literal: true

require "json"

require_relative "output_contract_check"
require_relative "output_recovery"

module Smith
  class Agent
    # Accepting an agent's response as its output. A refused response takes
    # the agent's refusal fallback once or raises OutputRefused; a cut-off
    # one is retried once with a larger output limit or raises
    # OutputTruncated (unless the agent accepts it). The response then goes
    # through the agent's `after_completion`; a structured output that is
    # not a JSON object, breaks a schema constraint or fails the agent's
    # output contract is sent back for repair up to `output_repairs`, then
    # raises OutputInvalid.
    #
    # No follow-up call is made once a tool has run in the step (the tools
    # would run again), once the call has spent what its step reserved, or
    # past MAX_CALLS; a follow-up that fails raises the output failure it
    # was making up for, with the provider's error as its cause. Every
    # response is billed; one that is set aside settles with the
    # invocation's failed attempts, and an :output_rejected trace names it.
    module OutputIntegrity
      include OutputRecovery

      # What one invocation has tried so far.
      Plan = Struct.new(:agent_class, :input, :output_schema, :json_schema, :repairs_left, :retried, :fell_back,
                        :output_limit, :calls) do
        def shape = ProviderRequest::Shape.new(output_schema:, output_limit:)
      end
      private_constant :Plan

      private

      # The agent's `output_schema`, else a static RubyLLM `schema` (a schema
      # given as a block is resolved by RubyLLM per chat, and not checked).
      def effective_output_schema(agent_class)
        return agent_class.output_schema if agent_class.output_schema

        schema = agent_class.schema if agent_class.respond_to?(:schema)
        schema unless schema.is_a?(Proc)
      end

      def output_plan(agent_class, prepared_input, output_schema)
        Plan.new(agent_class:, input: prepared_input, output_schema:, repairs_left: agent_class.output_repairs,
                 json_schema: output_schema && Providers::SchemaConstraints.json_schema(output_schema), calls: 1)
      end

      # nil when the output is accepted; otherwise a callable that makes the
      # next attempt. Raises the output failure when nothing is left to try.
      def output_follow_up(plan, attempt, result)
        failure = stop_failure(plan, attempt, result) || content_failure(plan, attempt, result)
        return unless failure

        follow_up = recovery(plan, attempt, result, failure)
        record_rejection(plan, attempt, failure, follow_up)
        raise failure unless follow_up

        follow_up
      end

      def stop_failure(plan, attempt, result)
        case Providers::StopReason.classify(stop_reason_of(attempt))
        when :refused then output_failure(OutputRefused, plan, attempt, result)
        when :truncated
          accepted = plan.agent_class.on_truncation[:policy] == :accept
          output_failure(OutputTruncated, plan, attempt, result) unless accepted
        end
      end

      # After the agent's `after_completion`, which sees every response the
      # provider did not refuse or cut off. A blank output is left to
      # BlankAgentOutputError.
      def content_failure(plan, attempt, result)
        result.content = run_after_completion(plan.agent_class, result.content, @context)
        return if blank_agent_output?(result.content)

        parse_structured_output!(plan, result)
        problems = output_problems(plan, result.content)
        output_failure(OutputInvalid, plan, attempt, result, problems) unless problems.empty?
      end

      # A structured output that reached Smith as JSON text (its schema
      # parsing bypassed) is read as RubyLLM reads a schema response.
      def parse_structured_output!(plan, result)
        return unless (plan.output_schema || plan.agent_class.output_contract) && result.content.is_a?(String)

        parsed = JSON.parse(result.content)
        result.content = parsed if parsed.is_a?(Hash)
      rescue JSON::ParserError
        nil
      end

      def output_problems(plan, content)
        contract = plan.agent_class.output_contract
        return [] unless plan.output_schema || contract
        return ["/: is not a JSON object"] unless content.is_a?(Hash)

        schema = plan.json_schema && Providers::SchemaConstraints.problems(plan.json_schema["schema"], content)
        Array(schema) + OutputContractCheck.problems(contract, content)
      end

      # A billed response that is not the invocation's output settles with
      # its failed attempts.
      def settle_rejected(agent_result)
        add_failed_agent_results([agent_result])
        Thread.current[:smith_last_agent_result] = nil
      end

      def record_rejection(plan, attempt, failure, follow_up)
        Smith::Trace.record(
          type: :output_rejected,
          data: { agent: plan.agent_class.register_as, attempt_id: attempt.attempt_id,
                  error_class: failure.class.name, stop_reason: failure.stop_reason,
                  problem_count: failure.problems.length, follow_up: follow_up ? next_step(failure) : :none }
        )
      end

      def next_step(failure)
        case failure
        when OutputRefused then :fallback
        when OutputTruncated then :retry
        else :repair
        end
      end

      def stop_reason_of(attempt) = attempt.completion.response_facts[:stop_reason]

      def output_failure(error_class, plan, attempt, result, problems = [])
        error_class.new(agent_name: plan.agent_class.register_as, model_used: result.model_used,
                        stop_reason: stop_reason_of(attempt), problems:)
      end
    end
  end
end
