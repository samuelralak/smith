# frozen_string_literal: true

require "dry-struct"

require_relative "../types"

module Smith
  class Tool < RubyLLM::Tool
    class ArgumentSnapshotResult < Dry::Struct
      attribute :value, Types::Hash
      attribute :node_count, Types::Integer.constrained(gteq: 1)
      attribute :byte_count, Types::Integer.constrained(gteq: 0)
    end
  end
end
