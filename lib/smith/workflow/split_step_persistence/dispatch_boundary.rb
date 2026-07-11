# frozen_string_literal: true

module Smith
  class Workflow
    module SplitStepPersistence
      module DispatchBoundary
        private

        def dispatch_store!(...)
          @split_step_dispatch_started = true if @split_step_phase == :preparing
          super
        end
      end
    end
  end
end
