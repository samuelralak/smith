# frozen_string_literal: true

require_relative "prepared_step"
require_relative "prepared_step_dispatch"
require_relative "split_step_persistence/execution_binding_snapshot"
require_relative "../errors"

module Smith
  class Workflow
    class PreparedStepExecutionAuthorization
      attr_reader :prepared_step, :dispatch_claim

      def initialize(prepared_step:, dispatch_claim:, execution_bindings:)
        unless prepared_step.is_a?(PreparedStep)
          raise ArgumentError, "prepared_step must be a Smith::Workflow::PreparedStep"
        end
        unless dispatch_claim.nil? || dispatch_claim.is_a?(PreparedStepDispatch)
          raise ArgumentError, "dispatch_claim must be a Smith::Workflow::PreparedStepDispatch or nil"
        end
        if dispatch_claim && dispatch_claim.prepared_step.to_h != prepared_step.to_h
          raise ArgumentError, "dispatch claim must belong to the prepared step"
        end
        unless execution_bindings.is_a?(SplitStepPersistence::ExecutionBindingSnapshot)
          raise ArgumentError, "execution_bindings must be a Smith execution binding snapshot"
        end

        @prepared_step = prepared_step
        @dispatch_claim = dispatch_claim
        @execution_bindings = execution_bindings
        @process_id = Process.pid
        freeze
      end

      def issued_in_current_process? = @process_id == Process.pid

      def fetch_agent!(...)
        ensure_current_process!

        @execution_bindings.fetch!(...)
      end

      def verify_workflow!(workflow_class)
        ensure_current_process!
        @execution_bindings.verify_workflow!(workflow_class)
      end

      def initialize_copy(_source)
        raise TypeError, "prepared-step execution authorizations cannot be copied"
      end

      def _dump(_depth)
        raise TypeError, "prepared-step execution authorizations cannot be serialized"
      end

      def encode_with(_coder)
        raise TypeError, "prepared-step execution authorizations cannot be serialized"
      end

      def init_with(_coder)
        raise TypeError, "prepared-step execution authorizations cannot be deserialized"
      end

      def as_json(*)
        raise TypeError, "prepared-step execution authorizations cannot be serialized"
      end

      def to_json(*)
        raise TypeError, "prepared-step execution authorizations cannot be serialized"
      end

      private

      def ensure_current_process!
        return if issued_in_current_process?

        raise WorkflowError, "prepared-step execution authorization belongs to another process"
      end
    end
  end
end
