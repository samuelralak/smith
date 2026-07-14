# frozen_string_literal: true

require "dry-initializer"

module Smith
  class Workflow
    module SplitStepPersistence
      class ReplaceExactSignature
        extend Dry::Initializer

        CONTRACT_KEYWORDS = %i[expected_payload ttl].freeze

        param :callable

        def valid? = accepts_two_values? && accepts_keywords?

        private

        def parameters = callable.parameters

        def accepts_two_values?
          required = parameters.count { |kind, _| kind == :req }
          positional = parameters.count { |kind, _| %i[req opt].include?(kind) }
          rest = parameters.any? { |kind, _| kind == :rest }
          required <= 2 && (positional >= 2 || rest)
        end

        def accepts_keywords?
          required_keywords_supported? && contract_keywords_accepted?
        end

        def required_keywords_supported?
          required = parameters.filter_map { |kind, name| name if kind == :keyreq }
          (required - CONTRACT_KEYWORDS).empty?
        end

        def contract_keywords_accepted?
          return true if parameters.any? { |kind, _| kind == :keyrest }

          keywords = parameters.filter_map { |kind, name| name if %i[key keyreq].include?(kind) }
          CONTRACT_KEYWORDS.all? { |name| keywords.include?(name) }
        end
      end
    end
  end
end
