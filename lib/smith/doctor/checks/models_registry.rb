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

        # Walk Smith::Agent::Registry. For each agent, extract the model
        # id from chat_kwargs (static `model "..."` form). Block-form
        # `model do |ctx| ... end` agents are skipped because their
        # model is resolved per-attempt and can't be enumerated at boot.
        # Check whether find_or_infer returns a custom (non-default)
        # Profile — meaning either an explicit override or an inference
        # rule matched.
        def uncovered_models
          return [] unless defined?(Smith::Agent::Registry)

          model_ids = []
          Smith::Agent::Registry.each do |_key, agent|
            next unless agent.is_a?(Class)
            next unless agent.respond_to?(:chat_kwargs)

            id = agent.chat_kwargs[:model]
            model_ids << id if id
          end

          model_ids.uniq.reject do |model_id|
            Smith::Models.find(model_id) ||
              (defined?(Smith::Models::Inference) && Smith::Models::Inference.profile_for(model_id))
          end
        end
      end
    end
  end
end
