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
          uncovered, ambiguous = classified_model_references
          report_ambiguous_models(report, ambiguous)
          report_model_coverage(report, uncovered)
        end

        def report_model_coverage(report, uncovered)
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

        # An unqualified agent model id registered under more than one
        # provider cannot resolve to a single profile: chat construction
        # fails closed with AmbiguousProfileError. Doctor must report that
        # configuration instead of crashing on it.
        def report_ambiguous_models(report, ambiguous)
          return if ambiguous.empty?

          descriptions = ambiguous.map { |reference| ambiguous_reference_description(reference) }
          report.add(
            name: "models.ambiguity",
            status: :fail,
            message: "#{ambiguous.size} agent model id(s) match profiles from multiple registered providers",
            detail: "Ambiguous: #{descriptions.join("; ")}. Chat construction fails closed for " \
                    "these agents until each declares an explicit provider (for example " \
                    "model \"gpt-5\", provider: :openai) selecting exactly one registered profile."
          )
        end

        def ambiguous_reference_description(reference)
          "#{reference.model_id} (providers: #{registered_providers_for(reference).join(", ")})"
        end

        def registered_providers_for(reference)
          Smith::Models.all
                       .select { |profile| profile.model_id == reference.model_id }
                       .map { |profile| profile.provider.to_s }
        end

        # Walk Smith::Agent::Registry. For each agent, extract every static
        # model id Smith can know at boot: the primary `model "..."` value and
        # any static fallback models. Block-form primary models are skipped
        # because they resolve per-attempt, but their static fallbacks still
        # need coverage checks.
        # Check whether find_or_infer returns a custom (non-default)
        # Profile, meaning either an explicit override or an inference
        # rule matched. Returns [uncovered, ambiguous] reference lists.
        def classified_model_references
          return [[], []] unless defined?(Smith::Agent::Registry)

          uncovered = []
          ambiguous = []
          static_model_references.uniq(&:key).each do |reference|
            case model_coverage(reference)
            when :uncovered then uncovered << reference
            when :ambiguous then ambiguous << reference
            end
          end
          [uncovered, ambiguous]
        end

        def model_coverage(reference)
          covered_model?(reference) ? :covered : :uncovered
        rescue Smith::Models::AmbiguousProfileError
          :ambiguous
        end

        def static_model_references
          Smith::Agent::Registry.each.with_object([]) do |(_key, agent), references|
            references.concat(static_model_references_for(agent)) if inspectable_agent?(agent)
          end
        end

        def inspectable_agent?(agent)
          agent.is_a?(Class) && agent.respond_to?(:chat_kwargs)
        end

        def static_model_references_for(agent)
          primary = agent.chat_kwargs[:model]
          references = Array(agent.respond_to?(:fallback_models) ? agent.fallback_models : nil).dup
          if primary
            references.unshift(
              Smith::Agent::ModelReference.coerce(primary, provider: agent.chat_kwargs[:provider])
            )
          end
          references
        end

        def covered_model?(reference)
          Smith::Models.find(reference.model_id, provider: reference.provider) ||
            inferred_profile_matches?(reference)
        end

        def inferred_profile_matches?(reference)
          return false unless defined?(Smith::Models::Inference)

          profile = Smith::Models::Inference.profile_for(reference.model_id)
          profile && (reference.provider.nil? || profile.provider.to_sym == reference.provider)
        end
      end
    end
  end
end
