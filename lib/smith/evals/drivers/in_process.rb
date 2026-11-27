# frozen_string_literal: true

require "time"
require_relative "../driver"
require_relative "../errors"
require_relative "../subject_result"

module Smith
  module Evals
    module Drivers
      # Experimental; frozen with slice 1a.4. Smith's own driver (slice-1a
      # design, 5.2): it builds the subject's workflow on the sample's input
      # mapping, with the eval scope's values for the keys the class trusts
      # as scope keys (its provider_credentials and budget_ledger keys), and
      # runs it inside Smith::Evals.under(context) a step at a time
      # (`advance!`, as `run!` does, so the steps it ran are known even when
      # one raises) to its end or a wait, or with the subject's `until:`
      # until that state. A durable retry's wait is ended once it is due
      # (`retry_waits: :sleep`, as long as the step's retry_on says, with no
      # ceiling, as in production), or at once (`:immediate`), and the run
      # goes on, bounded by the step's own retry_on attempts; the runner
      # reads the same setting for its backoff before a trial's retry
      # (design 5.7), which stops at 30 seconds.
      # The default is :sleep, and :immediate under Smith::Testing (`require
      # "smith/testing"`), so a test suite never waits. Any other wait ends
      # the trial waiting.
      #
      # The mapping is the suite's code, so what it raises or a context
      # that is no Hash leaves `run` as the driver's own failure, and a
      # mapping that sets a trusted scope key to another value raises
      # ScopeConflict before anything runs; what the subject raises is
      # returned, SubjectResult.raised. `around_trial` (a callable taking the
      # trial and a block) wraps each attempt of a trial. A trial with a
      # candidate builds and runs its subject inside
      # Smith::Prompts.with_candidate, so it sends the candidate's texts.
      class InProcess < Driver
        RETRY_WAITS = %i[immediate sleep].freeze
        private_constant :RETRY_WAITS

        # retry_waits: nil for the default.
        def initialize(max_concurrency: 8, around_trial: nil, retry_waits: nil)
          super()
          unless max_concurrency.is_a?(Integer) && max_concurrency.positive?
            raise ArgumentError, "max_concurrency is a positive Integer"
          end
          unless around_trial.nil? || around_trial.respond_to?(:call)
            raise ArgumentError, "around_trial is nil or responds to call(trial, &run)"
          end
          unless retry_waits.nil? || RETRY_WAITS.include?(retry_waits)
            raise ArgumentError, "retry_waits is :immediate or :sleep"
          end

          @max_concurrency = max_concurrency
          @around_trial = around_trial
          @retry_waits = retry_waits
        end

        attr_reader :max_concurrency

        def retry_waits = @retry_waits || (defined?(::Smith::Testing) ? :immediate : :sleep)

        def isolation = @around_trial ? :around_trial : :none

        def around_trial(trial, &run) = @around_trial ? @around_trial.call(trial, &run) : run.call

        def run(trial, context)
          subject = trial.subject
          klass = subject.workflow_for(trial.variant)
          input = scoped(klass, mapped(subject, trial.sample), trial.scope)
          return drive_subject(klass, input, subject, context) unless trial.candidate

          Smith::Prompts.with_candidate(trial.candidate.texts) { drive_subject(klass, input, subject, context) }
        end

        private

        # What the subject raised is its own; the result is built after, so
        # a failure of the driver's own is the driver's.
        def drive_subject(klass, input, subject, context)
          started = clock
          workflow = raised = run_result = nil
          steps = []
          begin
            run_result = Smith::Evals.under(context) do
              workflow = klass.new(context: input)
              drive(workflow, subject.until_state, steps)
            end
          rescue StandardError => e
            raised = e
          end
          ended(workflow, run_result, raised, subject,
                child_runs: child_runs(klass, steps), duration_ms: elapsed(started))
        end

        def ended(workflow, run_result, raised, subject, **counts)
          return SubjectResult.raised(workflow, raised, keep: subject.keep, **counts) if raised

          SubjectResult.from_workflow(workflow, run_result, keep: subject.keep, until: subject.until_state, **counts)
        end

        def mapped(subject, sample)
          input = subject.input.call(sample)
          return input if input.is_a?(Hash)

          raise ArgumentError, "the suite's input mapping returned #{input.class}, not a Hash for the context"
        end

        # The eval scope's values for the keys the class trusts as scope
        # keys, written as Symbols, so its credential and ledger blocks see
        # the eval run's tenant.
        def scoped(klass, input, scope)
          keys = (klass.budget_ledger_scope_keys + klass.smith_provider_credentials_scope_keys).uniq
          keys.select { scope.key?(_1.to_s) }.each_with_object(input.dup) do |key, context|
            context.except!(*given(klass, input, key, scope.fetch(key.to_s)))[key] = scope.fetch(key.to_s)
          end
        end

        # The mapping's keys for `key` (a Symbol or its String), each with
        # the eval scope's value, or a ScopeConflict.
        def given(klass, input, key, value)
          named = input.keys.select { _1.to_s == key.to_s }
          return named if named.all? { input[_1] == value }

          raise ScopeConflict, "the input mapping sets #{key}, a scope key #{klass.name} trusts, to another value " \
                               "than the eval run's scope"
        end

        # To its end or `until_state`, each durable retry's wait ended; each
        # step it ran joins `steps` as it ends. Without `until_state` the
        # result is the run's own (`run!` once nothing is left to advance),
        # with the steps.
        def drive(workflow, until_state, steps)
          loop do
            advance(workflow, until_state, steps)
            wait = workflow.awaiting
            break if wait&.kind != :retry || reached?(workflow, until_state)

            end_retry_wait(workflow, wait)
          end
          result(workflow, until_state, steps)
        end

        def result(workflow, until_state, steps)
          return Workflow::RunResult.new(**workflow.run!.to_h, steps:) unless until_state

          Workflow::RunResult.new(state: workflow.state, output: steps.reverse.map { _1[:output] }.compact.first,
                                  steps:, context: workflow.to_state[:context], usage_entries: workflow.usage_entries)
        end

        def advance(workflow, until_state, steps)
          until reached?(workflow, until_state) || workflow.terminal? || workflow.waiting?
            step = workflow.advance!
            break unless step

            steps << step
          end
        end

        def reached?(workflow, until_state) = !until_state.nil? && workflow.state.to_s == until_state.to_s

        def end_retry_wait(workflow, wait)
          deadline = wait.deadline_at
          deadline = Time.iso8601(deadline) if deadline.is_a?(String)
          due = deadline - Time.now
          sleep(due) if retry_waits == :sleep && due.positive?
          workflow.expire_wait!(token: wait.token, now: deadline + 1)
        end

        # The child-run steps (map, call or spawn) whose children Smith's
        # inline launcher ran with the trial's attribution cleared: their
        # attempts reached no recorder. Smith does not say how many children
        # a step launched, so each such step counts once.
        def child_runs(klass, steps)
          return 0 unless Smith.config.run_launcher.is_a?(Smith::Launchers::Inline)

          steps.count { |step| klass.find_transition(step[:transition])&.child_runs? }
        end

        def clock = Process.clock_gettime(Process::CLOCK_MONOTONIC)

        def elapsed(started) = ((clock - started) * 1000).round
      end
    end
  end
end
