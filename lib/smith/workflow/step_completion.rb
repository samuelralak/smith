# frozen_string_literal: true

module Smith
  class Workflow
    module StepCompletion
      private

      def complete_step(transition, output)
        step = { transition: transition.name, from: transition.from, to: transition.to, output: output }
        result = SplitStepPersistence
                 .instance_method(:prepare_split_step_execution_result)
                 .bind_call(self, step)
        StepCompletion.instance_method(:append_accepted_output).bind_call(self, output)
        SplitStepPersistence
          .instance_method(:commit_split_step_execution_result!)
          .bind_call(self, result)
        @state = transition.to
        @next_transition_name = @router_next_transition || transition.success_transition
        @router_next_transition = nil
        emit_step_completed(transition, output)
        step
      end

      def append_accepted_output(output)
        return unless @session_messages && !output.nil?

        @session_messages << { role: :assistant, content: output }
      end
    end
  end
end
