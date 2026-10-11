# frozen_string_literal: true

require_relative "../attribution"
require_relative "thread_context_snapshot"

module Smith
  class Workflow
    module StepContext
      private

      def with_step_context(transition, &block)
        ThreadContextSnapshot.new.around do
          setup_step_context
          install_step_attribution(transition)
          install_step_idempotency_scope(transition)
          Thread.handle_interrupt(Object => :immediate, &block)
        rescue StandardError => e
          @outcome = nil
          GuardrailIntegration.instance_method(:handle_step_failure).bind_call(self, transition, e)
        ensure
          teardown_step_context
        end
      ensure
        flush_step_failure_emission
      end

      # Runs after the snapshot's interrupt mask has closed, so host
      # StepFailed handlers execute interruptible, exactly as StepCompleted
      # handlers do inside the step. The step context is gone by now, so the
      # run identity and workflow label are seeded explicitly; the failed
      # step's own transition facts travel in the staged step hash. Flushes
      # on every exit of with_step_context, including the re-raise paths.
      # The read-clear-mark triple is masked so an async interrupt cannot
      # strand a staged failure between read and clear; the marker lets the
      # unresolved-transition handler recognize an error this path already
      # emitted. Only the emission itself stays interruptible.
      def flush_step_failure_emission
        step = nil
        Thread.handle_interrupt(Object => :never) do
          step = @pending_step_failure
          @pending_step_failure = nil
          @emitted_step_failure_error = step[:error] if step
        end
        return unless step

        Attribution.with(execution_key: @persistence_key, workflow: self.class.name || "anonymous") do
          emit_step_failed(step)
        end
      end

      def within_raw_step_context(&block)
        ThreadContextSnapshot.new.around do
          setup_step_context
          Thread.handle_interrupt(Object => :immediate, &block)
        ensure
          teardown_step_context
        end
      end

      def setup_step_context
        Tool.current_deadline = wall_clock_deadline
        Tool.current_ledger = @ledger
        Tool.current_tool_result_collector = tool_result_collector
      end

      # The ambient attribution for this step. Restoration is owned by the
      # surrounding ThreadContextSnapshot (the attribution thread key is one
      # of its THREAD_KEYS), so installation is a plain assignment. A nil
      # persistence key preserves any host-seeded outer execution_key, and
      # `workflow` is always a string ("anonymous" when the class has no
      # name) so a nested child always overrides the parent's label. The
      # per-step facts (transition, from, to) are replaced verbatim, nil
      # included: a nested child's `from: nil` transition must not inherit
      # the parent step's `from` through the nil-ignoring merge. branch_key
      # and round inherit deliberately (a child genuinely runs within them).
      def install_step_attribution(transition)
        Attribution.install(
          Attribution.ambient
                     .merge(execution_key: @persistence_key, workflow: self.class.name || "anonymous")
                     .override(transition: transition.name, from: transition.from, to: transition.to)
        )
      end

      # The step's position for idempotency keys: its number and transition
      # in this run's namespace. A nested workflow sharing the namespace (an
      # in-process child) is placed under the parent's current position, so
      # a child step never takes a key a parent step already used; any other
      # workflow started inside a step is a run of its own. Restoration is
      # owned by the surrounding ThreadContextSnapshot.
      def install_step_idempotency_scope(transition)
        namespace = ArtifactIntegration.instance_method(:execution_namespace).bind_call(self)
        outer = IdempotencyKey.__send__(:current_scope)
        base = outer && outer.run == namespace ? outer : IdempotencyKey.__send__(:root_scope, namespace)
        IdempotencyKey.__send__(:install, base.within(:step, @step_count + 1, transition.name.to_s))
      end

      def teardown_step_context
        Tool.current_guardrails = nil
        Tool.current_deadline = nil
        Tool.current_ledger = nil
        Tool.current_tool_result_collector = nil
        Smith.scoped_artifacts = nil
      end
    end
  end
end
