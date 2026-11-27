# frozen_string_literal: true

module Smith
  module Tuning
    class Loop
      # Internal. What a tuning run's lines say, and nothing more (slice 5a
      # design, section 2: the loop holds nothing the store does not): the
      # pool, with each candidate's validation scores and rotation pointer;
      # the run's generator and the minibatch cursor, as the last iteration
      # left them; the totals; the reflection replies of an iteration not
      # yet ended; the next iteration, how many ended, the validation
      # passes, the rounds since the best validation mean last rose, and
      # what stopped the run for good (a stop it goes on from writes no
      # line). `restore` folds stored lines into it, O(L C)
      # for L lines and C components; a running loop keeps it the same way,
      # line by line (`count`).
      class State
        attr_reader :pool, :rng, :minibatches, :totals, :reflections, :iteration, :iterations, :validation_passes,
                    :rounds, :stop

        def self.restore(lines, seed:, split:, settings:)
          ended = lines.select { _1["type"] == "iteration" }
          last = ended.last
          state = new(Pool.new(components: seed.prompts.keys, validation_ids: split.validation_ids),
                      **where(last, ended, split.train_ids, settings))
          ended.each { state.fold(_1, seed) }
          lines.each { |line| state.stash(line, last) if line["type"] == "reflection" }
          state
        end

        # The generator, the minibatches and the totals as the last ended
        # iteration left them; a new run's from its seed.
        def self.where(last, ended, train_ids, settings)
          size = settings.minibatch
          unless last
            return { rng: Evals::Statistics::SplitMix64.new(settings.seed), totals: Totals.new,
                     minibatches: Minibatches.new(train_ids, size:) }
          end

          drawn = ended.flat_map { _1.dig("minibatch", "sample_ids") || [] }
          { rng: Evals::Statistics::SplitMix64.from_hex(last["rng"]), totals: Totals.new(last["totals"]),
            minibatches: Minibatches.restore(train_ids, size:, cursor: last["cursor"], drawn:) }
        end
        private_class_method :where

        def initialize(pool, rng:, minibatches:, totals:)
          @pool = pool
          @rng = rng
          @minibatches = minibatches
          @totals = totals
          @reflections = {}
          @iteration = @iterations = @validation_passes = @rounds = 0
          @best = @stop = nil
        end

        # A stored iteration line: its parent's pointer moved (unless the
        # minibatch was perfect) and its child added again, as the first
        # run did.
        def fold(line, seed)
          parent = line.dig("parent", "index")
          picked = parent && pool.component(parent)
          replayed!(line, "rotated to #{picked}") unless picked == line["component"]
          pool.next_component(parent) if parent && line["ended_as"] != "perfect_minibatch"
          joined(line, parent ? pool[parent] : seed) if line.dig("child", "index")
          count(line)
        end

        # A stored reflection line: its spend is in the totals of the
        # iteration that ended after it; one of an iteration not yet ended
        # is kept, so the replayed iteration reads it instead of asking.
        def stash(line, last)
          return reflections[line["iteration"]] = line if last.nil? || line["iteration"] > last["iteration"]

          totals.seen(line)
        end

        # A line the loop wrote, or folded: the counts, the best and the stop.
        def count(line)
          @iteration = line["iteration"] + 1
          @iterations += 1
          @validation_passes += 1 if line["validation"]
          improved(pool.empty? ? nil : pool.mean(pool.best))
          @stop = line["stop"]&.then { { code: _1["code"], detail: _1["detail"] } }
        end

        def stopped(stop) = @stop = stop

        private

        # The rounds since the best validation mean last rose.
        def improved(best)
          @rounds = best && (@best.nil? || best > @best) ? 0 : @rounds + 1
          @best = best
        end

        def joined(line, parent)
          child = line["child"]
          candidate = line["parent"] ? made(line, parent) : parent
          replayed!(line, "made #{candidate.candidate_id}") unless candidate.candidate_id == child["candidate_id"]
          pool.add(candidate, line.dig("validation", "scores"))
        end

        def made(line, parent)
          child = line["child"]
          parent.child(line["component"], child["text"], iteration: line["iteration"],
                                                         parent: line.dig("parent", "index"), idea: child["idea"])
        end

        def replayed!(line, what)
          raise ArgumentError, "the record does not replay: iteration #{line["iteration"]} #{what}"
        end
      end

      # Internal. A run's totals as an iteration line keeps them, and what
      # the dollar stop's reserve reads: the subject's mean cost a metric
      # call and the costliest reflection.
      class Totals
        def initialize(line = nil)
          line ||= { "metric_calls" => 0, "provider_calls" => 0, "cost_nanos" => 0, "cost_complete" => true,
                     "reflection_calls" => 0 }
          @counts = line.slice("metric_calls", "provider_calls", "cost_nanos", "reflection_calls")
          @complete = line["cost_complete"]
          @reflections = @costliest = 0
        end

        def metric_calls = @counts["metric_calls"]
        def cost_nanos = @counts["cost_nanos"]
        def to_h = @counts.merge("cost_complete" => @complete)

        def usage
          { cost_nanos:, cost_complete: @complete, provider_calls: @counts["provider_calls"],
            reflection_calls: @counts["reflection_calls"] }
        end

        def pass(pass)
          add("metric_calls" => pass.metric_calls, "provider_calls" => pass.provider_calls,
              "cost_nanos" => pass.cost_nanos)
          @complete &&= pass.cost_complete
        end

        def reflection(line)
          usage = line["usage"]
          add("reflection_calls" => 1, "provider_calls" => usage["provider_calls"], "cost_nanos" => usage["cost_nanos"])
          @complete &&= usage["cost_complete"]
          seen(line)
        end

        # A reflection whose spend the totals hold already.
        def seen(line)
          cost = line.dig("usage", "cost_nanos")
          @reflections += cost
          @costliest = [@costliest, cost].max
        end

        # One more iteration at most: 2b + n_val metric calls at the mean
        # subject cost and the costliest reflection, times 1.25.
        def reserve(minibatch:, validation:)
          return 0 if metric_calls.zero?

          mean = Rational(cost_nanos - @reflections, metric_calls)
          (((((2 * minibatch) + validation) * mean) + @costliest) * Rational(5, 4)).ceil
        end

        private

        def add(amounts) = amounts.each { |key, amount| @counts[key] += amount }
      end
    end
  end
end
