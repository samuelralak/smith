# frozen_string_literal: true

require "dry-initializer"

module Smith
  class Tool < RubyLLM::Tool
    class ArgumentSnapshot
      MAX_DEPTH = ArgumentSnapshotTraversal::MAX_DEPTH
      MAX_NODES = ArgumentSnapshotTraversal::MAX_NODES
      MAX_BYTES = ArgumentSnapshotTraversal::MAX_BYTES

      extend Dry::Initializer

      param :value

      def call = ArgumentSnapshotTraversal.new(value).call
    end
  end
end
