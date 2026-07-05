# frozen_string_literal: true

module Smith
  module Doctor
    module Checks
      # Validates that every registered agent's resolved model has either:
      #   (a) an explicit application-side Smith::Models.register override, OR
      #   (b) a matching Smith::Models::Inference rule (library-shipped).
      #
      # If neither, the model gets safe defaults (no thinking, accepts temp,
      # no tool routing) which may silently degrade behavior. Reports the
      # uncovered models so hosts know to register overrides or rely on
      # the safe defaults knowingly.
      module ModelsRegistry
        module_function

        def run(report)
          uncovered = uncovered_models
          if uncovered.empty?
            report.add(
              name: "models.coverage",
              status: :pass,
              message: "All registered agents have model profiles or matching inference rules"
            )
          else
            report.add(
              name: "models.coverage",
              status: :warn,
              message: "#{uncovered.size} agent model(s) without explicit profile or matching inference rule",
              detail: "Uncovered: #{uncovered.join(", ")}. These models will get safe defaults " \
                      "(no thinking, accepts temperature, no tool routing). Either register an " \
                      "explicit Smith::Models::Profile via Smith::Models.register, OR add an " \
                      "Inference rule via Smith::Models::Inference.prepend_rule if the model " \
                      "fits an existing provider pattern."
            )
          end
        end

        # Walk Smith::Agent::Registry. For each agent, extract every static
        # model id Smith can know at boot: the primary `model "..."` value and
        # any static fallback models. Block-form primary models are skipped
        # because they resolve per-attempt, but their static fallbacks still
        # need coverage checks.
        # Check whether find_or_infer returns a custom (non-default)
        # Profile — meaning either an explicit override or an inference
        # rule matched.
        def uncovered_models
          return [] unless defined?(Smith::Agent::Registry)

          static_model_ids.uniq.reject { |model_id| covered_model?(model_id) }
        end

        def static_model_ids
          Smith::Agent::Registry.each.with_object([]) do |(_key, agent), ids|
            ids.concat(static_model_ids_for(agent)) if inspectable_agent?(agent)
          end
        end

        def inspectable_agent?(agent)
          agent.is_a?(Class) && agent.respond_to?(:chat_kwargs)
        end

        def static_model_ids_for(agent)
          [
            agent.chat_kwargs[:model],
            *(agent.respond_to?(:fallback_models) ? agent.fallback_models : nil)
          ].compact
        end

        def covered_model?(model_id)
          Smith::Models.find(model_id) ||
            (defined?(Smith::Models::Inference) && Smith::Models::Inference.profile_for(model_id))
        end
      end
    end
  end
end
