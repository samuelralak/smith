# frozen_string_literal: true

module Smith
  class Workflow
    module DefinitionIdentity
      module ClassMethods
        def inherited(subclass)
          super
          digest = definition_identity_mutex.synchronize { @definition_digest }
          subclass.instance_variable_set(:@definition_digest, digest)
          subclass.instance_variable_set(:@definition_identity_mutex, Mutex.new)
          subclass.instance_variable_set(:@definition_identity_sealed, false)
        end

        def definition_digest(value = nil)
          return definition_identity_mutex.synchronize { @definition_digest } if value.nil?

          unless Smith::Types::Sha256Hex.valid?(value)
            raise ArgumentError, "definition_digest must be a lowercase SHA-256 hex digest"
          end

          digest = value.dup.freeze
          definition_identity_mutex.synchronize do
            return @definition_digest if @definition_digest == digest
            if @definition_identity_sealed || frozen?
              raise ArgumentError, "definition_digest is sealed for this workflow class"
            end

            @definition_digest = digest
          end
        end

        private

        def seal_definition_identity!
          definition_identity_mutex.synchronize do
            @definition_identity_sealed = true unless frozen?
            @definition_digest
          end
        end

        def definition_identity_mutex
          @definition_identity_mutex ||= Mutex.new
        end
      end
    end
  end
end
