# frozen_string_literal: true

module Smith
  module Tuning
    class Loop
      # Internal. What a tuning run is set up from, worked out afresh on
      # every open: the suite's selection, the objective scorer, the run's
      # id (from the key, the scope's digest and the suite's name), the
      # split, and the seed (the components the suite's driver declares,
      # with their base texts as they are now, which the header's tuning
      # digest holds a resume to). A suite that
      # records no content is refused: the reflection reads the minibatch
      # trials' messages, and would read none. `header` is
      # what the run writes, or must match; `seam` is Smith's own
      # Evaluation::InProcess for it.
      Setup = Data.define(:selection, :scorer, :tuning_run_id, :split, :seed) do
        def self.build(suite, settings, scope, key)
          selection = recorded!(suite, scope)
          id = Evals::Identity.tuning_run_id(key:, scope:, suite: selection.manifest["name"])
          new(selection:, scorer: objective(suite, settings.objective), tuning_run_id: id,
              split: Split.given(selection.samples, **settings.split, at: Time.now),
              seed: Candidate.seed(prompts(suite), components: settings.components, tuning_run_id: id))
        end

        # The components the suite's driver declares, as named prompts.
        def self.prompts(suite)
          driver = suite.driver || Evals::Drivers::InProcess.new
          driver.components(suite.subject).to_h { |id, text| [id, Prompt.new(id, text)] }
        end

        # The suite's selection, unless the suite records no content.
        def self.recorded!(suite, scope)
          selection = suite.selection(scope:)
          return selection if selection.manifest.dig("recording", "content")

          raise ArgumentError, "the suite records no content (recording content: false), so a reflection would " \
                               "read none of a trial's messages"
        end

        def self.objective(suite, name)
          entry = suite.scorers.find { _1.name == name }
          entry&.scorer or raise ArgumentError, "objective names #{name}, which the suite does not score"
        end
        private_class_method :recorded!, :prompts, :objective

        def samples = selection.samples.to_h { [_1.id, _1] }

        def header(settings, scope:, started_by:, idempotency_key:)
          Record.header(tuning_run_id:, scope:, created_at: Time.now, started_by:, idempotency_key:, selection:,
                        settings:, split:, seed:, reveals_expected: scorer.reveals_expected,
                        host_code_version: Evals.config.host_code_version)
        end

        def seam(suite, settings, scope:, store:, started_by:)
          Evaluation::InProcess.new(suite:, scope:, store:, started_by:, objective: settings.objective, samples:,
                                    train_ids: split.train_ids, base_versions: seed.versions,
                                    reflection: Reflection::Runner.new(settings.reflection, scope:))
        end
      end
    end
  end
end
