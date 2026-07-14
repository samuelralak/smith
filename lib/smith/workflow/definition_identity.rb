# frozen_string_literal: true

require_relative "definition_identity/class_methods"

module Smith
  class Workflow
    module DefinitionIdentity
      def self.included(base)
        base.instance_variable_set(:@definition_identity_mutex, Mutex.new)
        base.instance_variable_set(:@definition_identity_sealed, false)
        base.extend(ClassMethods)
      end

      private

      def effective_definition_digest
        if instance_variable_defined?(:@split_step_definition_digest)
          @split_step_definition_digest
        else
          self.class.definition_digest
        end
      end
    end
  end
end
