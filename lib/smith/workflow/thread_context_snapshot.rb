# frozen_string_literal: true

require "dry-initializer"

require_relative "process_local"

module Smith
  class Workflow
    class ThreadContextSnapshot
      extend Dry::Initializer
      include ProcessLocal

      TOOL_ATTRIBUTES = %i[
        current_guardrails
        current_deadline
        current_ledger
        current_tool_call_allowance
        current_tool_result_collector
      ].freeze
      THREAD_KEYS = %i[
        smith_call_deadline
        smith_call_ledger
        smith_failed_agent_results
        smith_last_agent_result
        smith_parallel_agent_binding
      ].freeze

      option :tool_attributes, default: proc { TOOL_ATTRIBUTES }
      option :thread_keys, default: proc { THREAD_KEYS }
      option :scoped_artifacts, default: proc { true }

      def initialize(...)
        super
        @tool_attributes = tool_attributes.dup.freeze
        @thread_keys = thread_keys.dup.freeze
        validate_selection!
        @tool_values = capture_tool_values
        @thread_values = capture_thread_values
        @artifact_store = Smith.scoped_artifacts if scoped_artifacts
        @process_id = Process.pid
        @thread = Thread.current
        @fiber = Fiber.current
        @restored = false
      end

      def restore!
        ensure_owner!
        Thread.handle_interrupt(Object => :never) { restore_context! }
        self
      end

      def around
        ensure_owner!
        Thread.handle_interrupt(Object => :never) do
          raise WorkflowError, "thread context snapshot has already been restored" if @restored

          begin
            yield
          ensure
            restore_context!
          end
        end
      end

      private

      def restore_context!
        raise WorkflowError, "thread context snapshot has already been restored" if @restored

        @tool_values.each { |attribute, value| Tool.public_send("#{attribute}=", value) }
        @thread_values.each { |key, value| Thread.current[key] = value }
        Smith.scoped_artifacts = @artifact_store if scoped_artifacts
        @restored = true
      end

      def capture_tool_values
        tool_attributes.to_h { |attribute| [attribute, Tool.public_send(attribute)] }.freeze
      end

      def capture_thread_values
        thread_keys.to_h { |key| [key, Thread.current[key]] }.freeze
      end

      def ensure_owner!
        owner = @process_id == Process.pid && @thread.equal?(Thread.current) && @fiber.equal?(Fiber.current)
        return if owner

        raise WorkflowError, "thread context snapshot belongs to another process, thread, or fiber"
      end

      def validate_selection!
        unless (tool_attributes - TOOL_ATTRIBUTES).empty?
          raise ArgumentError, "thread context snapshot contains unsupported tool attributes"
        end
        return if (thread_keys - THREAD_KEYS).empty?

        raise ArgumentError, "thread context snapshot contains unsupported thread keys"
      end
    end

    private_constant :ThreadContextSnapshot
  end
end
