# frozen_string_literal: true

module Smith
  module Tuning
    class Loop
      # Internal. One iteration (slice 5a design, section 1, rows 1 to 7),
      # its line written when it ends. With an empty pool it scores the seed
      # on every validation sample. Otherwise: a parent drawn by the paper's
      # Algorithm 2 and its next component in rotation; the next training
      # minibatch; the parent's fresh run on it, with feedback; if every
      # score is perfect_score or more and skip_perfect is on, the end, with
      # no reflection and the parent's rotation not moved on (as DSPy's
      # run does); the reflection, its reply written as its own line the
      # moment it returns, and never asked again; the child, through
      # Prompt#with_text (a text that changes the fill-in fields ends it
      # proposal_invalid); the child's run on the same minibatch; kept only
      # if its mean is strictly higher; then its validation pass, after
      # which it joins the pool. A pass or reflection whose stop is final
      # (Stops::FINAL) ends the iteration incomplete, the stop in its line;
      # one stopped by the cap or an error that stops every run writes no
      # line, so the run, called again, replays the iteration. Each
      # evaluation's key is "<tuning run id>/<iteration>/<role>", so a
      # replayed iteration pays for no recorded trial and its eval runs go
      # on from where they stopped.
      module Iteration
        # Runs the next iteration and writes its line.
        def iterate!
          raise ArgumentError, "the run has stopped" if finished? || @state.stop

          @state.pool.empty? ? seeded(@state.iteration) : searched(@state.iteration)
        end

        private

        def seeded(number)
          seed = @setup.seed
          pass = evaluate(seed, @setup.split.validation_ids, number, "seed")
          base = { child: { candidate: seed, index: nil, minibatch: nil }, validation: pass }
          return stopped(number, base, pass) if pass.stop

          joined(number, base, seed, pass)
        end

        def searched(number)
          pool = @state.pool
          index = pool.pick(@state.rng)
          parent = pool[index]
          component = pool.component(index)
          ids = @state.minibatches.next(@state.rng)
          pass = evaluate(parent, ids, number, "parent", component:)
          base = { parent: [parent, index], component:, minibatch: [ids, pass] }
          return stopped(number, base, pass) if pass.stop
          return ended(number, :perfect_minibatch, **base) if perfect?(pass)

          proposed(number, base, reflected(number, parent, component, pass))
        end

        def perfect?(pass)
          @settings.skip_perfect && pass.scores.values.all? { _1 >= @settings.perfect_score }
        end

        # Past a perfect minibatch, the parent's rotation moves on.
        def proposed(number, base, line)
          @state.pool.next_component(base[:parent].last)
          return halted(number, base, code: line["stop"], detail: "the reflection call stopped: #{line["stop"]}") if
            line["stop"]
          return ended(number, :reflection_failed, **base) unless line["output"]

          child = child_of(number, base, line["output"]) or return ended(number, :proposal_invalid, **base)
          tried(number, base, child)
        end

        # The parent's child with the reply's text, or nil when the text
        # does not keep the component's fill-in fields.
        def child_of(number, base, output)
          parent, index = base[:parent]
          parent.child(base[:component], output["instruction"], iteration: number, parent: index, idea: output["idea"])
        rescue PromptInvalid
          nil
        end

        def tried(number, base, child)
          ids, parent_pass = base[:minibatch]
          pass = evaluate(child, ids, number, "child")
          base = base.merge(child: { candidate: child, index: nil, minibatch: pass })
          return stopped(number, base, pass) if pass.stop
          return ended(number, :rejected, **base) unless pass.mean > parent_pass.mean

          pass = evaluate(child, @setup.split.validation_ids, number, "validation")
          return stopped(number, base.merge(validation: pass), pass) if pass.stop

          joined(number, base, child, pass)
        end

        # A candidate kept, with its validation pass, joins the pool.
        def joined(number, base, candidate, pass)
          index = @state.pool.add(candidate, pass.scores)
          ended(number, :accepted, **base, child: base[:child].merge(index:), validation: pass)
        end

        # The iteration's reflection line: the stored one, or the reply of a
        # call made now, written at once. A call the cap or an error that
        # stops every run stopped is not written, so it is asked again.
        def reflected(number, parent, component, pass)
          line = @state.reflections[number]
          unless line
            call = @trials.reflect(message(parent, component, pass), trial_id: trial_id(number))
            line = Record.reflection(tuning_run_id:, iteration: number, call:)
            append(line) unless call.stop && Stops.resumable?(call.stop)
          end
          @state.totals.reflection(line)
          line
        end

        def trial_id(number) = Evals::Identity.reflection_trial_id(tuning_run_id:, iteration: number)

        def message(parent, component, pass)
          Reflection.message(component:, instruction: parent.texts[component], fields: parent.prompts[component].fields,
                             examples: examples(pass), training: @setup.split.train_ids)
        end

        # Each sample's run, through the one rule that withholds its
        # expected answer unless the scorer opts in.
        def examples(pass)
          reveals = @setup.scorer.reveals_expected
          samples = @setup.samples
          pass.samples.map do |id, sample|
            Reflection.example(samples.fetch(id), steps: sample.steps, score: sample.score, feedback: sample.feedback,
                                                  reveals_expected: reveals)
          end
        end

        def evaluate(candidate, sample_ids, number, role, component: nil)
          kind = %w[seed validation].include?(role) ? :tuning_validation : :tuning_minibatch
          pass = @trials.evaluate(candidate, sample_ids:, kind:, key: "#{tuning_run_id}/#{number}/#{role}", component:)
          @state.totals.pass(pass)
          pass
        end

        def stopped(number, base, pass) = halted(number, base, **Stops.of(pass.stop, pass.eval_run_id))

        # A final stop ends the iteration incomplete; any other abandons it.
        def halted(number, base, **stop)
          Stops.resumable?(stop[:code]) ? abandoned(stop) : ended(number, :incomplete, **base, stop:)
        end

        # The run stops with no line for the iteration: called again, it
        # replays it.
        def abandoned(stop)
          @state.stopped(stop)
          nil
        end

        def ended(number, ended_as, stop: nil, **parts)
          line = Record.iteration(tuning_run_id:, iteration: number, ended_as:, totals: @state.totals.to_h,
                                  rng: @state.rng, cursor: @state.minibatches.cursor, stop:, **parts)
          @state.count(append(line))
          line
        end
      end
    end
  end
end
