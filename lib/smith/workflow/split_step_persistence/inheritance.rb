# frozen_string_literal: true

module Smith
  class Workflow
    module SplitStepPersistence
      module Inheritance
        def inherited(subclass)
          super
          subclass.prepend(SubclassBoundary)
        end
      end
    end
  end
end
