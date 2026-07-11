# frozen_string_literal: true

require "dry-struct"

require_relative "../types"

module Smith
  class Workflow
    class PreparedStep < Dry::Struct
      DIGEST_PATTERN = /\A[0-9a-f]{64}\z/
      UUID_PATTERN = /\A[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}\z/i
      OwnedString = Types::String.constructor do |value|
        value.is_a?(String) ? value.dup.freeze : value
      end
      private_constant :OwnedString

      attribute :token, OwnedString.constrained(format: UUID_PATTERN)
      attribute :transition, OwnedString.constrained(min_size: 1)
      attribute :from, OwnedString.constrained(min_size: 1)
      attribute :persistence_key, OwnedString.constrained(min_size: 1)
      attribute :persistence_version, Types::Integer.constrained(gteq: 1)
      attribute :step_number, Types::Integer.constrained(gteq: 1)
      attribute :preparation_digest, OwnedString.constrained(format: DIGEST_PATTERN)

      def initialize(attributes)
        super
        self.attributes.freeze
        freeze
      end
    end
  end
end
