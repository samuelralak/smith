# frozen_string_literal: true

module Smith
  class Tool < RubyLLM::Tool
    class ExecutionBatchCollection
      MAX_CALLS = 100

      HASH_MATCH = Module.instance_method(:===)
      HASH_LENGTH = Hash.instance_method(:length)
      HASH_EACH_PAIR = Hash.instance_method(:each_pair)
      HASH_INITIALIZE_COPY = Hash.instance_method(:initialize_copy)
      OBJECT_RESPOND_TO = Object.instance_method(:respond_to?)
      REQUIRED_CALL_READERS = %i[name arguments].freeze
      private_constant :HASH_MATCH, :HASH_LENGTH, :HASH_EACH_PAIR, :HASH_INITIALIZE_COPY, :OBJECT_RESPOND_TO,
                       :REQUIRED_CALL_READERS

      def self.capture(tool_calls)
        size = admitted_size(tool_calls)
        captured = owned_copy(tool_calls)
        validate_copy_size!(captured, size)
        indexed_calls(captured)
      end

      def self.admitted_size(tool_calls)
        raise Error, "unsupported RubyLLM tool-call collection" unless HASH_MATCH.bind_call(Hash, tool_calls)

        size = HASH_LENGTH.bind_call(tool_calls)
        return size if size.positive? && size <= MAX_CALLS

        raise Error, "provider tool batch must contain between 1 and #{MAX_CALLS} calls"
      end
      private_class_method :admitted_size

      def self.owned_copy(tool_calls)
        Hash.allocate.tap do |copy|
          HASH_INITIALIZE_COPY.bind_call(copy, tool_calls)
          copy.freeze
        end
      end
      private_class_method :owned_copy

      def self.validate_copy_size!(captured, expected_size)
        return if HASH_LENGTH.bind_call(captured) == expected_size

        raise Error, "provider tool batch changed while it was being captured"
      end
      private_class_method :validate_copy_size!

      def self.indexed_calls(captured)
        snapshot = {}
        HASH_EACH_PAIR.bind_call(captured) do |_key, tool_call|
          validate_call!(tool_call)
          snapshot[snapshot.length] = tool_call
        end
        snapshot.freeze
      end
      private_class_method :indexed_calls

      def self.validate_call!(tool_call)
        supported = REQUIRED_CALL_READERS.all? do |reader|
          OBJECT_RESPOND_TO.bind_call(tool_call, reader)
        rescue TypeError
          false
        end
        raise Error, "provider tool batch contains an unsupported call" unless supported
      end
      private_class_method :validate_call!
    end
  end
end
