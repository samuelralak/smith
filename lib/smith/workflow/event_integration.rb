# frozen_string_literal: true

module Smith
  class Workflow
    module EventIntegration
      private

      def emit_step_completed(transition, _output)
        Smith::Events.emit(
          Events::StepCompleted.new(
            transition: transition.name,
            from: transition.from,
            to: transition.to
          )
        )
      end
    end
  end
end
