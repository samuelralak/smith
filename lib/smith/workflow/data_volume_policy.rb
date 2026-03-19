# frozen_string_literal: true

module Smith
  class Workflow
    module DataVolumePolicy
      LIGHTWEIGHT_SCALARS = [String, Integer, Float, Symbol, TrueClass, FalseClass, NilClass].freeze

      private

      def validate_data_volume!(output, agent_class)
        return unless agent_class.respond_to?(:data_volume)
        return unless agent_class.data_volume == :unbounded
        return unless output.is_a?(Hash)

        require_ref_key!(output)
        require_scalar_values!(output)
      end

      def require_ref_key!(output)
        return if output.keys.any? { |k| k.to_s.end_with?("_ref") }

        raise GuardrailFailed, "data_volume :unbounded requires at least one *_ref key"
      end

      def require_scalar_values!(output)
        output.each do |key, value|
          next if key.to_s.end_with?("_ref")
          next if LIGHTWEIGHT_SCALARS.any? { |type| value.is_a?(type) }

          raise GuardrailFailed,
                "data_volume :unbounded requires lightweight scalar values, got #{value.class} for :#{key}"
        end
      end
    end
  end
end
