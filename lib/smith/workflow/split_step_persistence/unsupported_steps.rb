# frozen_string_literal: true

module Smith
  class Workflow
    module SplitStepPersistence
      # The steps split-step persistence does not run, refused when one is
      # prepared, before anything is written.
      module UnsupportedSteps
        private

        def refuse_unsupported_split_step!(transition)
          return unless transition

          if transition.waits_or_launches?
            raise WorkflowError, "split-step persistence does not run steps that wait or launch runs"
          end
          return unless transition.from.nil?

          # A prepared step is checked against the state its step is declared
          # from, which a step declared `from: nil` does not have; not
          # supported yet.
          raise WorkflowError, "split-step persistence does not run :#{transition.name}: it is declared from: nil, " \
                               "and a prepared step is checked against the state its step is declared from; " \
                               "run it with advance_persisted!"
        end
      end
    end
  end
end
