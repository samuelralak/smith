# frozen_string_literal: true

require "dry-struct"

require_relative "../types"
require_relative "execution_result_snapshot"

module Smith
  class Workflow
    class PreparedStepExecutionResult < Dry::Struct
      attribute :status, Types::Symbol.enum(:succeeded, :failed)
      attribute :step, Types::Hash
      attribute? :error, Types.Instance(StandardError).optional

      def self.from_step(step)
        error = step[:error]
        new(status: error ? :failed : :succeeded, step:, error:)
      end

      def initialize(attributes)
        owned = attributes.dup
        owned[:step] = snapshot(owned.fetch(:step), freeze_copy: true, preserved_error: owned[:error])
        super(owned)
        validate_shape!
        self.attributes.freeze
        freeze
      end

      def succeeded? = status == :succeeded
      def failed? = status == :failed
      def step_snapshot = snapshot(step, freeze_copy: false, preserved_error: error)

      private

      def snapshot(value, freeze_copy:, preserved_error:)
        ExecutionResultSnapshot.new(value, freeze_copy:, preserved_error:).call
      end

      def validate_shape!
        valid = if failed?
                  error && step[:error].equal?(error)
                else
                  error.nil? && !step.key?(:error)
                end
        raise ArgumentError, "prepared-step execution result fields do not match status" unless valid
      end
    end
  end
end
