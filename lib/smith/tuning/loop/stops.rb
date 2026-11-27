# frozen_string_literal: true

module Smith
  module Tuning
    class Loop
      # Internal. The stop rules (slice 5a design, section 1, row 8),
      # checked before each iteration, in order: the cancel flag; metric
      # calls used at or over max_metric_calls; max_candidates; the
      # deadline; the dollar stop (spent plus one iteration's reserve over
      # max_cost_nanos); rounds_without_improvement, when set. An iteration
      # once begun runs to its end, so a run passes max_metric_calls by at
      # most 2b + n_val. And how a stop ends a run: cancelled; finished by a
      # rule above, with a proposal when the best beats the seed on
      # validation, else nothing_better; failed for good when a check
      # fails (candidate_not_sent, scorer_failed) or the subject cannot run
      # (definition_error, scope_conflict); otherwise stopped, to go on when
      # called again: at the cap (stopped_at_limit), or failed by an error
      # that stops every run (a refused key, no credit), which a host can
      # fix. `status` is what says a run can go on; `ended` is the outcome.
      module Stops
        FINISHED = %w[metric_calls cost candidates deadline no_improvement].freeze
        FINAL = %w[cancelled candidate_not_sent scorer_failed definition_error scope_conflict].freeze
        DETAILS = { cap_reached: "the cap refused calls in a pass", cancelled: "an eval run of the pass was cancelled",
                    candidate_not_sent: "a step sent another version of a component the candidate changed",
                    scorer_failed: "the objective scorer could not score a trial" }.freeze

        module_function

        # The first rule that stops the run now, as {code:, detail:}, or nil.
        # cancel: the run's cancel request or nil; validation: n_val.
        def check(state, settings, cancel:, validation:)
          return { code: "cancelled", detail: cancel["reason"] } if cancel

          stop = settings.stop
          budget(state.totals, stop) || pool(state, stop) || deadline(stop) ||
            cost(state.totals, stop, settings.minibatch, validation) || rounds(state, stop)
        end

        # A pass's or a reflection's stop, as {code:, detail:}.
        def of(code, eval_run_id = nil)
          detail = DETAILS.fetch(code) { "eval run #{eval_run_id} stopped: #{code}" }
          { code: code.to_s, detail: }
        end

        # Whether a pass's or a reflection's stop leaves the run to go on
        # when called again.
        def resumable?(code) = !FINAL.include?(code.to_s)

        # [status, ended] for a stop; best: the pool's best index or nil.
        def ended(stop, best)
          case stop.fetch(:code)
          when "cancelled" then %i[cancelled cancelled]
          when "cap_reached" then %i[stopped stopped_at_limit]
          when *FINISHED then [:finished, best.to_i.positive? ? :proposal : :nothing_better]
          when *FINAL then %i[failed failed]
          else %i[stopped failed]
          end
        end

        def budget(totals, stop)
          limit = stop[:max_metric_calls]
          used = totals.metric_calls
          { code: "metric_calls", detail: "#{used} of #{limit} metric calls used" } if limit && used >= limit
        end

        def pool(state, stop)
          size = state.pool.size
          { code: "candidates", detail: "#{size} candidates" } if size >= stop[:max_candidates]
        end

        def deadline(stop)
          at = stop[:deadline]
          return unless at && Time.now >= at

          { code: "deadline", detail: "the deadline #{Evals::Store::Clock.timestamp(at)} passed" }
        end

        def cost(totals, stop, minibatch, validation)
          limit = stop[:max_cost_nanos] or return
          reserve = totals.reserve(minibatch:, validation:)
          spent = totals.cost_nanos
          return unless spent + reserve > limit

          { code: "cost", detail: "#{spent} nanos spent and #{reserve} kept for one more iteration" }
        end

        def rounds(state, stop)
          limit = stop[:rounds_without_improvement]
          return unless limit && state.rounds >= limit

          { code: "no_improvement", detail: "#{state.rounds} iterations without a better candidate" }
        end
      end
    end
  end
end
