# frozen_string_literal: true

require "dry-initializer"

module Smith
  class Workflow
    class Graph
      # A durable retry waits out its backoff in the store, so its longest
      # backoff (jitter included) must end within the persistence TTL, or
      # the stored run would expire while it waits. At runtime such a wait
      # fails the step only after earlier attempts and waits.
      class DurableRetryDiagnostic
        extend Dry::Initializer

        param :graph

        def to_a
          ttl = graph.workflow_class.persistence_ttl || Smith.config.persistence_ttl
          return [] unless ttl

          graph.reachable_transitions.filter_map do |transition|
            config = transition.retry_config
            next unless config&.fetch(:durable, false)

            longest = longest_backoff(config)
            diagnostic(transition.name, longest, ttl) if longest >= ttl
          end
        end

        private

        def longest_backoff(config)
          attempts = config.fetch(:attempts)
          ExponentialBackoff.new(attempts:, base_delay: config.fetch(:backoff), max_delay: config[:max_delay],
                                 jitter: config.fetch(:jitter), delay_label: "backoff")
                            .delay(attempts - 1, random: -> { ExponentialBackoff::MAX_RANDOM_FACTOR })
        end

        def diagnostic(name, longest, ttl)
          Diagnostic.new(
            severity: :error, code: :durable_retry_outlasts_ttl, transition: name,
            message: "Transition #{Reference.format(name)} waits up to #{longest.round(3)} seconds between attempts, " \
                     "which does not end within the persistence TTL of #{ttl} seconds.",
            suggestion: "Lower backoff, max_delay or jitter, or raise the persistence TTL."
          )
        end
      end
    end
  end
end
