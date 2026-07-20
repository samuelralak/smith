# frozen_string_literal: true

module Smith
  class Workflow
    module PreparedBranchExecution
      private

      def prepared_branch(implementation, *arguments)
        tool_context = Tool::ScopedContext.capture
        unless @split_step_active_execution_authorization
          return proc do |signal|
            Tool::ScopedContext.around(tool_context) do
              __send__(implementation.name, *arguments, signal)
            end
          end
        end

        proc do |signal|
          run = proc { implementation.bind_call(self, *arguments, signal) }
          Tool::ScopedContext.around(tool_context) do
            PreparedBranchExecution.instance_method(:within_prepared_branch_execution).bind_call(self, &run)
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
