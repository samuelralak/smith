# frozen_string_literal: true

module Smith
  module Tuning
    # Experimental. A candidate (slice 5a design, sections 2 and 3; plan
    # 5.1): a text for each tuned component, held as the component's
    # Smith::Prompt so its version is the text's digest. The seed takes the
    # subject's named prompts (Smith::Prompts.components); a child changes
    # one component through Prompt#with_text, which refuses a text whose
    # fill-in fields differ (PromptInvalid). Its id is the run's, the
    # iteration that made it and every component's version
    # (Evals::Identity.candidate_id); `parent` is its parent's index in the
    # pool, and its own index is the pool's. Frozen. O(C) for C components.
    class Candidate
      attr_reader :candidate_id, :tuning_run_id, :iteration, :parent, :component, :idea, :prompts

      # prompts: the subject's named prompts by component id; components:
      # those tuned, in rotation order, or nil for all of them in theirs.
      def self.seed(prompts, components:, tuning_run_id:)
        raise ArgumentError, "the subject sends no named prompt to tune" if prompts.empty?

        missing = (components || []) - prompts.keys
        raise ArgumentError, "components names #{missing.first}, which the subject does not send" unless missing.empty?

        new(tuning_run_id:, iteration: 0, parent: nil, component: nil, idea: nil,
            prompts: (components || prompts.keys).to_h { [_1, prompts.fetch(_1)] })
      end

      def initialize(tuning_run_id:, iteration:, parent:, component:, idea:, prompts:)
        @tuning_run_id = tuning_run_id
        @iteration = iteration
        @parent = parent
        @component = component
        @idea = idea
        @prompts = prompts.freeze
        @candidate_id = Evals::Identity.candidate_id(tuning_run_id:, iteration:, versions:)
        freeze
      end

      # The same texts but `component`'s, made at `iteration` from the
      # candidate at index `parent`.
      def child(component, text, iteration:, parent:, idea: nil)
        prompt = prompts[component] or raise ArgumentError, "#{component} is not a tuned component"
        raise ArgumentError, "a child's iteration is at least 1" unless iteration.is_a?(Integer) && iteration.positive?

        Candidate.new(tuning_run_id:, iteration:, parent:, component:, idea:,
                      prompts: prompts.merge(component => prompt.with_text(text)))
      end

      def texts = prompts.transform_values(&:text)
      def versions = prompts.transform_values(&:version)

      # The eval run header's candidate: the texts live in the tuning record.
      def reference
        { "candidate_id" => candidate_id, "tuning_run_id" => tuning_run_id,
          "components" => versions.map { |id, version| { "id" => id, "version" => version } } }
      end
    end
  end
end
