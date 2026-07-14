# frozen_string_literal: true

module Smith
  class Workflow
    module DefinitionIdentity
      module ClassMethods
        def inherited(subclass)
          super
          subclass.instance_variable_set(:@definition_digest, @definition_digest)
        end

        def definition_digest(value = nil)
          return @definition_digest if value.nil?

          unless Smith::Types::Sha256Hex.valid?(value)
            raise ArgumentError, "definition_digest must be a lowercase SHA-256 hex digest"
          end

          @definition_digest = value.dup.freeze
        end
      end
    end
  end
end
