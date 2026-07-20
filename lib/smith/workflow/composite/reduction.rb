# frozen_string_literal: true

require_relative "../../types"
require_relative "effects"
require_relative "error"

module Smith
  class Workflow
    module Composite
      class Reduction < Dry::Struct
        attribute :status, Types::Symbol.enum(:succeeded, :failed)
        attribute? :output, Types::Any.optional
        attribute? :error, Types.Instance(Error).optional
        attribute? :failed_branch_key, Types::String.optional
        attribute :effects, Types.Instance(Effects)

        def initialize(attributes)
          super
          valid = status == :succeeded ? error.nil? && failed_branch_key.nil? : error && failed_branch_key
          raise ArgumentError, "composite reduction fields do not match status" unless valid

          self.attributes.freeze
          freeze
        end

        def succeeded? = status == :succeeded
        def failed? = status == :failed
      end
    end
  end
end
