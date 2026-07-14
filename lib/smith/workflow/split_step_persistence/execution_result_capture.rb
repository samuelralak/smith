# frozen_string_literal: true

module Smith
  class Workflow
    module SplitStepPersistence
      module ExecutionResultCapture
        private

        def capture_split_step_execution_result!(step)
          result = prepare_split_step_execution_result(step)
          commit_split_step_execution_result!(result)
        end

        def prepare_split_step_execution_result(step)
          return unless active_split_step_execution_thread?

          PreparedStepExecutionResult.from_step(step)
        end

        def commit_split_step_execution_result!(result)
          return unless result

          @split_step_mutex.synchronize do
            return unless active_split_step_execution_thread?
            raise WorkflowError, "prepared-step execution produced more than one result" if @split_step_execution_result

            @split_step_execution_result = result
          end
        end

        def consume_split_step_execution_result!(execution_thread)
          @split_step_mutex.synchronize do
            unless @split_step_phase == :executing && @split_step_execution_thread.equal?(execution_thread)
              raise WorkflowError, "prepared-step execution is no longer active"
            end

            @split_step_execution_result ||
              raise(WorkflowError, "prepared-step execution did not produce a result")
          end
        end

        def active_split_step_execution_thread?
          @split_step_phase == :executing && @split_step_execution_thread.equal?(Thread.current)
        end
      end
    end
  end
end
