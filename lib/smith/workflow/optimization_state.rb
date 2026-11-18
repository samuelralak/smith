# frozen_string_literal: true

module Smith
  class Workflow
    # What an optimize step's callables read: `round` is the round under
    # way, from 0 in each attempt, the one its verdicts and captures name.
    OptimizationState = Struct.new(
      :config, :prepared_input, :candidate, :feedback, :last_score, :generator_class, :evaluator_class, :evaluations,
      :round
    ) do
      def initialize(config, prepared_input)
        super(config, prepared_input, nil, nil, nil, nil, nil, [].freeze, nil)
      end
    end
  end
end
