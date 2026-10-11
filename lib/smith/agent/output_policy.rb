# frozen_string_literal: true

module Smith
  class Agent
    # What an agent does with a response that cannot be its output:
    #
    #   on_truncation :fail                         # the default: OutputTruncated
    #   on_truncation :accept                       # keep the cut-off output
    #   on_truncation retry_with: { max_tokens: 32_000 }
    #   on_refusal :fail                            # the default: OutputRefused
    #   on_refusal fallback: "anthropic/claude-opus-5-5"
    #   output_contract ReviewContract              # checks an output_schema agent's Hash
    #   output_repairs 1                            # the default; 0 turns repair off
    #
    # A retry, a fallback and each repair are one more provider call, billed
    # like any other.
    module OutputPolicy
      MAX_REPAIRS = 3
      FAIL = { policy: :fail }.freeze
      private_constant :FAIL

      def on_truncation(policy = nil, retry_with: nil)
        return @on_truncation || FAIL if policy.nil? && retry_with.nil?

        @on_truncation = if one_of!("on_truncation", policy, %i[fail accept], retry_with)
                           { policy: :retry, max_tokens: retry_limit(retry_with) }.freeze
                         else
                           { policy: }.freeze
                         end
      end

      def on_refusal(policy = nil, fallback: nil)
        return @on_refusal || FAIL if policy.nil? && fallback.nil?

        @on_refusal = if one_of!("on_refusal", policy, %i[fail], fallback)
                        { policy: :fallback, model: refusal_fallback(fallback) }.freeze
                      else
                        FAIL
                      end
      end

      # Any object (or a class whose instances are such objects) whose
      # `call(hash)` returns a result answering `success?` and `errors`, as
      # a dry-validation contract does.
      def output_contract(contract = nil)
        return @output_contract if contract.nil?

        checker = contract.is_a?(Class) ? contract.new : contract
        raise ArgumentError, "output_contract must respond to call" unless checker.respond_to?(:call)

        @output_contract = checker
      end

      def output_repairs(count = nil)
        return @output_repairs || 1 if count.nil?
        unless count.is_a?(Integer) && count.between?(0, MAX_REPAIRS)
          raise ArgumentError, "output_repairs must be an Integer from 0 to #{MAX_REPAIRS}"
        end

        @output_repairs = count
      end

      private

      # True when the option is given; otherwise the policy must be one of
      # `policies`.
      def one_of!(macro, policy, policies, option)
        raise ArgumentError, "#{macro} takes a policy or an option, not both" if policy && option
        return true if option
        return false if policies.include?(policy)

        raise ArgumentError, "#{macro} takes #{policies.map(&:inspect).join(" or ")}, or an option"
      end

      def retry_limit(options)
        limit = options.is_a?(Hash) && options.keys == [:max_tokens] ? options[:max_tokens] : nil
        return limit if limit.is_a?(Integer) && limit.positive?

        raise ArgumentError, "on_truncation retry_with: takes { max_tokens: a positive Integer }"
      end

      def refusal_fallback(model)
        reference = ModelReference.coerce(model)
        return reference if reference.provider

        raise ArgumentError, "on_refusal fallback: must name a provider, as in \"anthropic/<model>\""
      rescue Dry::Struct::Error => e
        raise ArgumentError, "invalid on_refusal fallback: #{e.message}"
      end
    end
  end
end
