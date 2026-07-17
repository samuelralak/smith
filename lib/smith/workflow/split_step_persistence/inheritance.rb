# frozen_string_literal: true

module Smith
  class Workflow
    module SplitStepPersistence
      module Inheritance
        def inherited(subclass)
          super
          subclass.prepend(SubclassBoundary)
        end

        def prepend(*features)
          result = super
          guard = SubclassBoundary.guard
          guard.freeze
          Module.instance_method(:prepend).bind_call(self, guard)
          result
        end
      end
    end
  end
end
