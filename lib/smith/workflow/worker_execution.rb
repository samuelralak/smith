# frozen_string_literal: true

module Smith
  class Workflow
    # One worker's run in an orchestrate step. Its id goes to the
    # orchestrator in the next round's message, so it is named by the
    # worker's position (the run, step, round, task content and copy)
    # rather than drawn at random: a restored run sends that message as
    # before, and the response memo replays the orchestrator's reply.
    WorkerExecution = Struct.new(:execution_id, :task, :output) do
      def self.run(worker_class, task, schema, budget_runner)
        new(position_id, task, budget_runner.call(worker_class, task, schema))
      end

      # A UUID (version 8, RFC 9562) from a position no idempotency key
      # uses, so it gives away no key a step hands to another service.
      def self.position_id
        IdempotencyKey.__send__(:uuid, IdempotencyKey.__send__(:current_scope!).within(:worker_execution).key, 8)
      end
      private_class_method :position_id
    end
  end
end
