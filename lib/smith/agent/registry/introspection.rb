# frozen_string_literal: true

module Smith
  class Agent
    module Registry
      module Introspection
        def binding_for(name)
          registry_monitor.synchronize do
            key = normalize_key(name)
            item = _container[key]
            item ? Smith::Agent::RegistryBinding.new(key: key, item: item).to_h : nil
          end
        end

        def bindings
          registry_monitor.synchronize do
            _container.each_with_object({}) do |(key, item), binding_map|
              binding_map[key] = Smith::Agent::RegistryBinding.new(key: key, item: item).to_h
            end.freeze
          end
        end
      end

      extend Introspection
    end
  end
end
