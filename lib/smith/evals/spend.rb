# frozen_string_literal: true

module Smith
  module Evals
    # Internal. How a subject's usage adds up (the trial schema's usage and
    # its by_model): one entry for each provider and model, and the totals
    # summed from those entries, so by_model always sums to the usage beside
    # it. The recorder adds each step, a trial line each attempt's usage and
    # the summary each line's. The subject's spend only: judging (slice 2)
    # is counted apart. Not thread-safe: its owner locks. O(1) per entry
    # added; `usage` O(M log M) for M models.
    class Spend
      # The token kinds a usage counts (the trial schema's tokens), the one
      # list: the recorder's step records count the same.
      TOKENS = %w[input output cache_read cache_write thinking].freeze

      def initialize
        @models = {}
      end

      # What one step, or one usage's entry, spent on a provider and model;
      # a token count not given is 0.
      def add(provider:, model:, provider_calls:, tokens:, cost_nanos:, cost_complete:)
        entry = (@models[[provider, model]] ||= { "provider" => provider, "model" => model, "provider_calls" => 0,
                                                  "tokens" => TOKENS.to_h { [_1, 0] }, "cost_nanos" => 0,
                                                  "cost_complete" => true })
        entry["provider_calls"] += provider_calls
        TOKENS.each { |key| entry["tokens"][key] += (tokens || {}).fetch(key, 0) }
        entry["cost_nanos"] += cost_nanos
        entry["cost_complete"] &&= cost_complete
        self
      end

      # Each by_model entry of a usage Hash (a recorder's, a line's).
      def add_usage(usage)
        usage.fetch("by_model").each do |entry|
          add(**%w[provider model provider_calls tokens cost_nanos cost_complete].to_h { [_1.to_sym, entry.fetch(_1)] })
        end
        self
      end

      # tokens, cost_nanos (exact: integer nanos), cost_complete (false when
      # any cost was unknown, so the cost is a floor), provider_calls and
      # by_model, ordered by provider, then model (UTF-16 code units, an
      # unknown one first). Frozen.
      def usage
        sorted = @models.values.sort_by { |entry| [order(entry["provider"]), order(entry["model"])] }
        models = sorted.map { |entry| entry.merge("tokens" => entry["tokens"].dup.freeze).freeze }
        { **totals(models), "by_model" => models.freeze }.freeze
      end

      private

      def totals(models)
        { "tokens" => TOKENS.to_h { |key| [key, models.sum { _1["tokens"][key] }] }.freeze,
          "cost_nanos" => models.sum { _1["cost_nanos"] }, "cost_complete" => models.all? { _1["cost_complete"] },
          "provider_calls" => models.sum { _1["provider_calls"] } }
      end

      def order(name) = name.nil? ? [0, ""] : [1, name.encode(Encoding::UTF_16BE).b]
    end
  end
end
