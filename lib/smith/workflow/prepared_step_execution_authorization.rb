# frozen_string_literal: true

require_relative "prepared_step"
require_relative "prepared_step_dispatch"
require_relative "prepared_step_execution_scope"
require_relative "process_local"
require_relative "split_step_persistence/execution_binding_snapshot"
require_relative "../errors"

module Smith
  class Workflow
    class PreparedStepExecutionAuthorization
      include ProcessLocal

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
        issued_in_current_process? && @execution_scope.active_for?(Thread.current, Fiber.current)
      end

      private

      def within_branch_execution!(&)
        ensure_current_process!
        @execution_scope.within_branch(&)
      end

      def activate_execution!
        ensure_current_process!
        @execution_scope.activate!(Thread.current, Fiber.current)
      end

      def close_execution!
        @execution_scope.close!(Thread.current, Fiber.current)
      end

      def ensure_active_execution!
        return if active_in_current_execution?

        raise WorkflowError, "prepared-step execution authorization is outside its active execution"
      end

      def ensure_binding_access!
        accessible = issued_in_current_process? &&
                     @execution_scope.binding_accessible_for?(Thread.current, Fiber.current)
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
