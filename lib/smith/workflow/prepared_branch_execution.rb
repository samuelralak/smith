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
        unless @split_step_active_execution_authorization
          return proc do |signal|
            Attribution.carrying(ambient_attribution) do
              Tool::ScopedContext.around(tool_context) do
                __send__(implementation.name, *arguments, signal)
              end
            end
          end
        end

        proc do |signal|
          run = proc { implementation.bind_call(self, *arguments, signal) }
          Attribution.carrying(ambient_attribution) do
            Tool::ScopedContext.around(tool_context) do
              PreparedBranchExecution.instance_method(:within_prepared_branch_execution).bind_call(self, &run)
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
