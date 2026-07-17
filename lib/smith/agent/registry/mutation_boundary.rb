# frozen_string_literal: true

module Smith
  class Agent
    module Registry
      module MutationBoundary
        def merge(...)
          registry_monitor.synchronize { super }
        end

        def decorate(...)
          registry_monitor.synchronize { super }
        end

        def namespace(...)
          registry_monitor.synchronize { super }
        end

        def import(...)
          registry_monitor.synchronize { super }
        end

        def configure(...)
          registry_monitor.synchronize { super }
        end
      end
    end
  end
end
