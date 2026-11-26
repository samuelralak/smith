# frozen_string_literal: true

require_relative "evals"
require_relative "tuning/reflection"
require_relative "tuning/settings"
require_relative "tuning/split"
require_relative "tuning/minibatches"
require_relative "tuning/candidate"
require_relative "tuning/pool"
require_relative "tuning/evaluation"
require_relative "tuning/record"

module Smith
  # Experimental. The tuner (plan section 5, slice 5a): GEPA, written from
  # its paper (arXiv 2507.19457, Algorithms 1 and 2), which searches the
  # texts of a workflow's named prompts against an eval suite. Loaded only
  # by `require "smith/tuning"`, which loads Smith::Evals; `require
  # "smith"` loads none of it, and no file of it names the provider gem.
  #
  #   Smith::Tuning.record("tu_...", scope: { tenant: "ten_0193" })  # => Smith::Tuning::Record, or nil
  #   Smith::Tuning.cancel("tu_...", scope:, actor:, reason: "wrong split") # => :requested, or :exists
  #
  # Each takes `store:` (default Smith::Evals.config.store, which must keep
  # tuning runs) and `scope:` (default Smith::Evals.config.default_scope).
  module Tuning
    EXPERIMENTAL = true

    class << self
      # The run's record as its store holds it, or nil.
      def record(tuning_run_id, scope: nil, store: nil)
        store, scope = where(store, scope)
        header = store.read_tuning_header(scope:, tuning_run_id:) or return

        Record.new(header:, lines: store.each_tuning_line(scope:, tuning_run_id:).to_a,
                   summary: store.read_tuning_summary(scope:, tuning_run_id:))
      end

      # Flags the run cancelled; it stops before its next iteration.
      def cancel(tuning_run_id, actor:, reason: nil, scope: nil, store: nil)
        store, scope = where(store, scope)
        store.request_cancel(scope:, tuning_run_id:, actor:, reason:)
      end

      private

      def where(store, scope)
        store ||= Evals.config.store
        raise ArgumentError, "the store keeps no tuning runs (Smith::Evals::Store::TUNING_METHODS)" unless
          Evals::Store.tuning?(store)

        [store, Smith::Scope.build(scope || Evals.config.default_scope)]
      end
    end
  end
end
