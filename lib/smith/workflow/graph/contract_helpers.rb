# frozen_string_literal: true

module Smith
  class Workflow
    class Graph
      module ContractHelpers
        private

        def label_for(value)
          label = if value.respond_to?(:name) && value.name && !value.name.empty?
                    value.name
                  elsif value.respond_to?(:inspect)
                    value.inspect
                  else
                    value.to_s
                  end

          immutable_value(label)
        end

        def idempotency_mode
          return :unknown unless workflow_class.respond_to?(:idempotency_mode)

          workflow_class.idempotency_mode
        end

        def in_flight_resume
          return :blocked_by_step_in_progress if idempotency_mode == :strict
          return :unknown unless %i[strict lax].include?(idempotency_mode)

          :reruns_transition
        end

        def immutable_value(value)
          return value if immediate_value?(value)

          duplicate = value.dup
          return value if duplicate.equal?(value)

          duplicate.freeze
        rescue TypeError
          value
        end

        def immediate_value?(value)
          value.nil? || value.is_a?(Symbol) || value.is_a?(Numeric) ||
            value == true || value == false
        end

        def deep_freeze(value)
          case value
          when Hash
            value.each_value { |nested| deep_freeze(nested) }
            value.freeze
          when Array
            value.each { |nested| deep_freeze(nested) }
            value.freeze
          end

          value
        end
      end
    end
  end
end
