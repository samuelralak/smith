# frozen_string_literal: true

module Smith
  class Workflow
    module StepCompletion
      # Room for what completing a step adds besides its output (its state,
      # step count, last agent).
      RESULT_MARGIN = 1024

      private

      def complete_step(transition, output)
        StepCompletion.instance_method(:check_result_storable!).bind_call(self, output)
        step = { transition: transition.name, from: transition.from, to: transition.to, output: output }
        # Fold in the serial agent attribution captured for this step (if any),
        # then clear the transient carrier. record_step_snapshot reads these off
        # the returned step to update the durable @last_agent_execution.
        step.merge!(@pending_agent_execution.slice(:model, :provider)) if @pending_agent_execution

        @pending_agent_execution = nil
        fold_pending_evaluations(step)
        result = SplitStepPersistence
                 .instance_method(:prepare_split_step_execution_result)
                 .bind_call(self, step)
        StepCompletion.instance_method(:keep_accepted_output).bind_call(self, transition, output)
        SplitStepPersistence
          .instance_method(:commit_split_step_execution_result!)
          .bind_call(self, result)
        # Cleared only once the record is committed: a completion that fails
        # before this folds the same verdicts into its failure record.
        @pending_evaluations = nil
        @state = transition.to
        @next_transition_name = @router_next_transition || transition.success_transition
        @router_next_transition = nil
        emit_step_completed(transition, output)
        step
      end

      # A stored run's step whose result would take its state past
      # persistence_max_bytes fails with PersistedStateTooLarge before the
      # result is kept, as with any error: its usage is recorded, its
      # on_failure taken, and its run stays storable (strict mode
      # included), where a refused store after the step would leave it
      # unsaved. The estimate is the state's JSON and the output's, kept
      # twice (in the context or transcript, and as the last output).
      def check_result_storable!(output)
        limit = Smith.config.persistence_max_bytes
        return unless limit && @persistence_version.to_i.positive?

        bytes = JSON.generate(to_state).bytesize + (JSON.generate(output).bytesize * 2) + RESULT_MARGIN
        raise PersistedStateTooLarge.new(key: @persistence_key, bytes:, limit:) if bytes > limit
      rescue JSON::GeneratorError, JSON::NestingError, Encoding::UndefinedConversionError
        nil
      end

      # Once the result is captured, so a step whose result is refused leaves
      # neither the context nor the transcript changed.
      def keep_accepted_output(transition, output)
        StepIO.instance_method(:deliver_output_to).bind_call(self, transition, output) if transition.output_to
        StepCompletion.instance_method(:append_accepted_output).bind_call(self, transition, output)
      end

      # The transcript keeps an accepted output unless the step writes it to
      # the context (`output_to:`) or the session is isolated.
      def append_accepted_output(transition, output)
        return unless @session_messages && !output.nil? && transcript_output?(transition)

        @session_messages << { role: :assistant, content: output }
        @last_transcript_output = output
      end
    end
  end
end
