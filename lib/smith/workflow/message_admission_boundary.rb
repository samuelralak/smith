# frozen_string_literal: true

require_relative "message_batch"

module Smith
  class Workflow
    module MessageAdmissionBoundary
      def append_session_messages!(messages)
        admission = MessageBatch.new(messages).call
        @split_step_mutex.synchronize do
          SplitStepPersistence.instance_method(:ensure_no_split_step_boundary!).bind_call(self)
          unless @session_messages.nil? || @session_messages.is_a?(Array)
            raise WorkflowError, "workflow session messages are not appendable"
          end

          (@session_messages ||= []).concat(admission.messages)
        end
        admission
      end
    end
  end
end
