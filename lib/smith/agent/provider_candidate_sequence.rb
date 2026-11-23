# frozen_string_literal: true

module Smith
  class Agent
    class ProviderCandidateSequence
      include Enumerable

      # The chain an agent's attempts go through. Under run credentials
      # (Smith::RunCredentials), a candidate whose provider they do not cover
      # is passed over: yielded, so it is observed as skipped, but never sent
      # and never counted as a fallback. With no run credentials and
      # Smith.config.require_run_credentials on, no candidate is tried: the
      # step fails before anything is sent or any budget ledger asked.
      # The mode is read by key: on every agent invocation, the reader costs
      # about 0.3 microseconds more.
      def self.of(references, credentials, agent_class)
        unless credentials
          return new(references) unless Smith.config[:require_run_credentials]

          raise ProviderCredentialsMissing.new(
            "#{agent_class} ran outside any run with provider_credentials, which " \
            "Smith.config.require_run_credentials refuses", model_id: references.first&.model_id.to_s
          )
        end

        new(references, passed_over: credentials.passed_over(agent_class, references), credentials:)
      end

      def initialize(references, passed_over: [], credentials: nil)
        @references = references.freeze
        @passed_over = passed_over.freeze
        @credentials = credentials
        @remaining_by_provider = covered(references).each_with_object(Hash.new(0)) do |reference, counts|
          counts[reference.provider] += 1
        end
        @unavailable_providers = {}
        @available_count = references.length - passed_over.length
      end

      # Returns self so an exhausted sequence can never be mistaken for
      # an attempt result by a caller that forgets to fail closed.
      def each
        return enum_for(:each) unless block_given?

        references.each_with_index do |reference, index|
          next yield(reference, index) if @passed_over.include?(index)

          consume(reference)
          yield reference, index unless unavailable?(reference.provider)
        end
        self
      end

      # Whether the candidate at `index` is passed over; when it is, it is
      # observed as skipped (RunCredentials#skipped).
      def passed_over?(agent_class, reference, index)
        return false unless @passed_over.include?(index)

        @credentials.skipped(agent_class, reference, index)
        true
      end

      # Raises ProviderCredentialsMissing when the run's credentials covered
      # no candidate at all.
      def none_covered!
        @credentials.none_covered!(references) if !references.empty? && @passed_over.length == references.length
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

      # The candidates not passed over, which alone count as fallbacks left.
      def covered(references)
        return references if @passed_over.empty?

        references.reject.with_index { |_reference, index| @passed_over.include?(index) }
      end
    end
  end
end
