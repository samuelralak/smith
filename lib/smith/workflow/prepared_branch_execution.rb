# frozen_string_literal: true

module Smith
  class Workflow
    module PreparedBranchExecution
      private

      def prepared_branch(implementation, *arguments)
        tool_context = Tool::ScopedContext.capture
        # Attribution is captured on the preparing thread (where the step's
        # context is ambient) and carried into the branch thread, exactly as
        # the tool context is; carrying nil deliberately clears stale state
        # on a pooled thread.
        ambient_attribution = Attribution.current
        authorized = @split_step_active_execution_authorization
        # A collaborator's branch (a Method, as NestedItems passes) runs as it
        # is; the workflow's own by its name, as a host's override of it
        # always has, or as Smith defines it under a split step's authorization.
        run = if implementation.respond_to?(:call) then implementation
              elsif authorized then implementation.bind(self)
              else ->(*given) { __send__(implementation.name, *given) }
              end
        proc do |signal|
          Attribution.carrying(ambient_attribution) do
            Tool::ScopedContext.around(tool_context) do
              next run.call(*arguments, signal) unless authorized

              PreparedBranchExecution.instance_method(:within_prepared_branch_execution)
                                     .bind_call(self) { run.call(*arguments, signal) }
            end
          end
        end
      end

      def within_prepared_branch_execution(&)
        authorization = @split_step_active_execution_authorization
        return yield unless authorization

        PreparedStepExecutionAuthorization
          .instance_method(:within_branch_execution!)
          .bind_call(authorization, &)
      end
    end

    private_constant :PreparedBranchExecution
  end
end
