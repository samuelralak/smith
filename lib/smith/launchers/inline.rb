# frozen_string_literal: true

module Smith
  module Launchers
    # Runs each child to its end, one after another, in the parent's
    # process, and returns their results, so the parent's step completes at
    # once. Children run under the parent's deadline but with no tool
    # evidence or attribution of the parent's. A child launched again (its
    # parent restored after a crash, or a step around it tried again) is
    # the same run, named by its key: its tools repeat their idempotency
    # keys and it owns what it stored before. Its calls are kept under the
    # launching step's attempts too, as a nested workflow's are: a restore
    # replays them, a retry asks them again. Its finished steps run again,
    # so a call whose prompt names a value a step draws anew (a file, S3 or
    # Active Record artifact ref) misses the memo. A child left waiting, or
    # one that raised, is reported failed (with the error's class). For
    # tests and scripts: a long map holds the parent's step for as long as
    # it runs.
    class Inline
      def inline? = true

      def launch(children:, parent_key:, await_token:) # rubocop:disable Lint/UnusedMethodArgument
        deadline = Tool.current_deadline
        children.map { |child| run_child(child, deadline) }
      end

      private

      def run_child(child, deadline)
        workflow = built(child)
        workflow.instance_variable_set(:@inherited_deadline, deadline) if deadline
        run = apart { workflow.run! }
        return failed(child, workflow.state, "waiting") if workflow.waiting?

        ChildRun.result(ref: child.ref, run_result: run)
      rescue StandardError => e
        Interruptions.pass!(e)
        failed(child, nil, DiagnosticText.error_class_name(e))
      end

      # The child under the launching step's attempts, named by its key.
      def built(child)
        workflow = ResponseMemo.inheriting(ResponseMemo.__send__(:launching_attempts)) { child.build }
        workflow.instance_variable_set(:@execution_namespace, IdempotencyKey.__send__(:child_namespace, child.key))
        workflow
      end

      def failed(child, state, error)
        { ref: child.ref, status: "failed", state: state&.to_s, output: nil,
          error: DiagnosticText.capture(error.to_s, max_bytes: 256) }
      end

      def apart(&)
        tracker = Tool.current_tool_execution_tracker
        Tool.current_tool_execution_tracker = nil
        Attribution.carrying(nil, &)
      ensure
        Tool.current_tool_execution_tracker = tracker
      end
    end
  end
end
