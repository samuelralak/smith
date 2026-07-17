# frozen_string_literal: true

require_relative "prepared_step"
require_relative "prepared_step_dispatch"
require_relative "prepared_step_execution_scope"
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
        @execution_scope = PreparedStepExecutionScope.new
        @process_id = Process.pid
        freeze
      end

      def issued_in_current_process? = @process_id == Process.pid

      def fetch_agent!(...)
        ensure_binding_access!

        @execution_bindings.fetch!(...)
      end

      def each_agent_binding(&block)
        ensure_binding_access!
        raise ArgumentError, "a block is required to inspect captured agent bindings" unless block

        @execution_bindings.each_agent_binding(&block)
        self
      end

      def verify_workflow!(workflow_class)
        ensure_active_execution!
        @execution_bindings.verify_workflow!(workflow_class)
      end

      def active_in_current_execution?
        issued_in_current_process? && @execution_scope.active_for?(Thread.current)
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

      def activate_execution!(thread)
        ensure_current_process!
        @execution_scope.activate!(thread)
      end

      def close_execution!(thread = nil)
        @execution_scope.close!(thread)
      end

      def ensure_active_execution!
        return if active_in_current_execution?

        raise WorkflowError, "prepared-step execution authorization is outside its active execution"
      end

      def ensure_binding_access!
        accessible = issued_in_current_process? && @execution_scope.binding_accessible_for?(Thread.current)
        return if accessible

        raise WorkflowError, "prepared-step execution authorization is outside its binding access scope"
      end

      def ensure_current_process!
        return if issued_in_current_process?

        raise WorkflowError, "prepared-step execution authorization belongs to another process"
      end
    end
  end
end
