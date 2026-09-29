# frozen_string_literal: true

module Smith
  class Workflow
    OptimizationState = Struct.new(
      :config, :prepared_input, :candidate, :feedback, :last_score, :generator_class, :evaluator_class, :evaluations
    ) do
      def initialize(config, prepared_input)
        super(config, prepared_input, nil, nil, nil, nil, nil, [].freeze)
      end
    end
  end
end
