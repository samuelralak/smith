# frozen_string_literal: true

module Smith
  class Agent
    class ProviderCandidateSequence
      include Enumerable

      def initialize(references)
        @references = references.freeze
        @remaining_by_provider = references.each_with_object(Hash.new(0)) do |reference, counts|
          counts[reference.provider] += 1
        end
        @unavailable_providers = {}
        @available_count = references.length
      end

      # Returns self so an exhausted sequence can never be mistaken for
      # an attempt result by a caller that forgets to fail closed.
      def each
        return enum_for(:each) unless block_given?

        references.each_with_index do |reference, index|
          consume(reference)
          yield reference, index unless unavailable?(reference.provider)
        end
        self
      end

      def suppress(provider)
        return unless provider
        return if unavailable?(provider)

        unavailable_providers[provider] = true
        @available_count -= remaining_by_provider.fetch(provider, 0)
      end

      def fallback_available?
        @available_count.positive?
      end

      private

      attr_reader :references, :remaining_by_provider, :unavailable_providers

      def consume(reference)
        remaining_by_provider[reference.provider] -= 1
        @available_count -= 1 unless unavailable?(reference.provider)
      end

      def unavailable?(provider)
        unavailable_providers.key?(provider)
      end
    end
  end
end
