# frozen_string_literal: true

require "dry-struct"

require_relative "../types"

module Smith
  class Tool < RubyLLM::Tool
    class InvocationRequest < Dry::Struct
      MAX_ARGUMENT_DEPTH = ArgumentSnapshot::MAX_DEPTH
      MAX_ARGUMENT_NODES = ArgumentSnapshot::MAX_NODES
      MAX_ARGUMENT_BYTES = ArgumentSnapshot::MAX_BYTES

      ToolClass = Types::Any.constructor do |value|
        raise TypeError, "expected a Smith::Tool subclass" unless value.is_a?(Class) && value <= Smith::Tool

        value
      end
      private_constant :ToolClass

      attribute :invocation, Types.Instance(Invocation)
      attribute :tool_class, ToolClass
      attribute :arguments, Types::Hash

      attr_reader :argument_node_count, :argument_byte_count

      def initialize(...)
        super
        snapshot = ArgumentSnapshot.new(arguments).call
        @argument_node_count = snapshot.node_count
        @argument_byte_count = snapshot.byte_count
        @attributes = @attributes.merge(arguments: snapshot.value).freeze
        freeze
      end
    end
  end
end
