# frozen_string_literal: true

require "securerandom"

module Smith
  class Workflow
    WorkerExecution = Struct.new(:execution_id, :task, :output) do
      def self.run(worker_class, task, schema, budget_runner)
        new(SecureRandom.uuid, task, budget_runner.call(worker_class, task, schema))
      end
    end
  end
end
