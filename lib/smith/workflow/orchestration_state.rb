# frozen_string_literal: true

module Smith
  class Workflow
    OrchestrationState = Struct.new(
      :config, :prepared_input, :orchestrator_class, :worker_class, :worker_results
    ) do
      def initialize(config, prepared_input)
        super(config, prepared_input, nil, nil, nil)
      end
    end
  end
end
