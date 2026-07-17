# frozen_string_literal: true

module Smith
  class Agent
    module Registry
      module ExecutionBindingCapture
        def capture_bindings!(requests)
          registry_monitor.synchronize do
            requests.each_with_object({}) do |request, bindings|
              key = normalize_key(request.fetch(:name))
              binding = binding_for(key)
              klass = binding&.fetch(:agent_class, nil)
              unless klass
                raise Smith::WorkflowError,
                      "unresolved #{request.fetch(:role)} :#{key}" \
                      "#{fetch_suffix(request.fetch(:workflow_class), request.fetch(:transition_name))}"
              end

              bindings[key] = klass
            end.freeze
          end
        end
      end
    end
  end
end
