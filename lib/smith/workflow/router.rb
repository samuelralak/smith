# frozen_string_literal: true

module Smith
  class Workflow
    class Router
      def self.resolve(classifier_output, config, workflow_class:)
        validate!(classifier_output, config)
        transition_name = select_transition(classifier_output, config)
        validate_transition_exists!(transition_name, workflow_class)
        transition_name
      end

      def self.validate!(output, config)
        validate_structure!(output)
        validate_confidence!(output[:confidence])
        validate_route_key!(output[:route].to_sym, output[:confidence], config)
      end

      def self.validate_structure!(output)
        raise WorkflowError, "router classifier output must be a Hash" unless output.is_a?(Hash)
        raise WorkflowError, "router classifier output missing :route" unless output.key?(:route)
        raise WorkflowError, "router classifier output missing :confidence" unless output.key?(:confidence)
      end

      def self.validate_confidence!(confidence)
        return if confidence.is_a?(Numeric) && confidence >= 0.0 && confidence <= 1.0

        raise WorkflowError, "router confidence must be a number in 0.0..1.0"
      end

      def self.validate_route_key!(route_key, confidence, config)
        return if confidence < config[:confidence_threshold]
        return if config[:routes].key?(route_key)

        raise WorkflowError, "router route :#{route_key} not found in declared routes"
      end

      def self.select_transition(output, config)
        if output[:confidence] >= config[:confidence_threshold]
          config[:routes][output[:route].to_sym]
        else
          config[:fallback]
        end
      end

      def self.validate_transition_exists!(transition_name, workflow_class)
        return if workflow_class.find_transition(transition_name)

        raise WorkflowError, "router selected transition :#{transition_name} which is not declared on the workflow"
      end
    end
  end
end
