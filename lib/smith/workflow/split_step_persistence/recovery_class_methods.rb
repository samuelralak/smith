# frozen_string_literal: true

module Smith
  class Workflow
    module SplitStepPersistence
      module RecoveryClassMethods
        def recover_prepared_step(recovery, adapter: Smith.persistence_adapter)
          seal_definition_identity!
          allocate.send(:recover_prepared_step, recovery, adapter)
        end
      end
    end
  end
end
