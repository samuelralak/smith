# frozen_string_literal: true

require "dry-initializer"

module Smith
  class Workflow
    class Graph
      class RuntimeBindingDiagnosticBuilder
        extend Dry::Initializer

        param :graph
        option :binding

        def to_diagnostic
          registry_binding = Agent::Registry.binding_for(agent)
          return unresolved_agent_diagnostic unless registry_binding

          if registry_binding.fetch(:agent_class).nil?
            return uninspectable_agent_diagnostic(registry_binding) if registry_binding.fetch(:call)

            return invalid_agent_diagnostic(registry_binding.fetch(:raw_binding))
          end

          agent_class = registry_binding.fetch(:agent_class)
          return if agent_class.model_configured?
          return required_model_diagnostic if model_required?

          model_warning
        end

        private

        def unresolved_agent_diagnostic
          Diagnostic.new(
            severity: :error,
            code: :unresolved_agent_binding,
            transition: transition.name,
            target: agent,
            message: "Transition #{ref(transition.name)} references unregistered #{role} #{ref(agent)}.",
            suggestion: "Load and register agent #{ref(agent)} before running workflow #{workflow_label}."
          )
        end

        def invalid_agent_diagnostic(raw_binding)
          Diagnostic.new(
            severity: :error,
            code: :invalid_agent_binding,
            transition: transition.name,
            target: agent,
            message: "Transition #{ref(transition.name)} references #{role} #{ref(agent)}, " \
                     "but the registry binding is not a Smith::Agent subclass.",
            suggestion: "Register #{ref(agent)} as a Smith::Agent subclass instead of " \
                        "#{raw_binding.class}."
          )
        end

        def uninspectable_agent_diagnostic(registry_binding)
          Diagnostic.new(
            severity: model_required? ? :error : :warning,
            code: :uninspectable_agent_binding,
            transition: transition.name,
            target: agent,
            message: "Transition #{ref(transition.name)} references #{role} #{ref(agent)}, " \
                     "but the registry binding is lazy and cannot be inspected without resolving it.",
            suggestion: "Register #{ref(registry_binding.fetch(:key))} as a concrete Smith::Agent subclass " \
                        "before relying on static runtime readiness."
          )
        end

        def required_model_diagnostic
          Diagnostic.new(
            severity: :error,
            code: :agent_without_required_model,
            transition: transition.name,
            target: agent,
            message: "Transition #{ref(transition.name)} references #{role} #{ref(agent)}, " \
                     "but that role requires model output at runtime.",
            suggestion: "Configure a model for agent #{ref(agent)} or move this transition to a " \
                        "deterministic/nested workflow pattern."
          )
        end

        def model_warning
          Diagnostic.new(
            severity: :warning,
            code: :agent_without_model,
            transition: transition.name,
            target: agent,
            message: "Transition #{ref(transition.name)} references #{role} #{ref(agent)}, " \
                     "but the registered agent has no model configured.",
            suggestion: "Configure a model for agent #{ref(agent)} if this transition should call a provider."
          )
        end

        def agent
          binding.fetch(:agent)
        end

        def transition
          binding.fetch(:transition)
        end

        def role
          binding.fetch(:role)
        end

        def model_required?
          binding.fetch(:requires_model)
        end

        def ref(value)
          Reference.format(value)
        end

        def workflow_label
          name = graph.workflow_class.name
          return name if name && !name.empty?

          graph.workflow_class.inspect
        end
      end
    end
  end
end
