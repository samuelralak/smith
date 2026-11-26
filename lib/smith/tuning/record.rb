# frozen_string_literal: true

module Smith
  module Tuning
    # Experimental; format version 0, frozen as 1 when slice 5a ends. A
    # tuning run's record (slice 5a design, section 3;
    # docs/evals/schemas/tuning-*.schema.json): the builders of its header,
    # its lines and its summary, and the reader of what a store holds.
    #
    # The header is written once. A reflection line is written the moment
    # its call returns, so a restart never asks it again; an iteration line
    # when the iteration ends, with the run's totals, the generator's state
    # and the minibatch cursor, so the lines alone restore a run. A
    # candidate's line holds only the text it changed: its other texts are
    # its lineage's, and the seed's are the subject's, named by the
    # header's base versions. `digest` is what a restart must match: the
    # header without its ids, times and actors.
    class Record
      FORMAT_VERSION = 0
      FORMATS = Evals::Store::TuningRecords::FORMATS
      # A reply that is not {idea, instruction} is a failed call.
      REPLY_INVALID = { "kind" => "reply_invalid", "error_class" => "Smith::Tuning::Reflection",
                        "message" => "the reply is not {idea, instruction}" }.freeze

      # A candidate as the record holds it: its texts are those its lineage
      # changed (the subject's for the rest), its versions every
      # component's; `metric_calls` is the run's count when it joined.
      Candidate = Data.define(:index, :candidate_id, :parent, :component, :idea, :texts, :versions, :scores, :mean,
                              :metric_calls)

      class << self
        # selection: the suite's Selection; seed: the seed Candidate.
        def header(tuning_run_id:, scope:, created_at:, started_by:, idempotency_key:, selection:, settings:, split:,
                   seed:, host_code_version:)
          header = Parts.format_of(:header).merge(
            "tuning_run_id" => tuning_run_id, "scope" => Smith::Scope.build(scope),
            "created_at" => Evals::Store::Clock.timestamp(created_at), "started_by" => started_by&.to_h,
            "idempotency_key" => idempotency_key
          ).merge(Parts.measured(selection, settings.objective))
          header.merge!("components" => seed.versions.map { |id, version| { "id" => id, "base_version" => version } },
                        "split" => split.to_h, "settings" => settings.to_h)
          environment = { "smith_version" => Smith::VERSION, "host_code_version" => host_code_version }
          header.merge("tuning_digest" => digest(header.merge("environment" => environment)),
                       "environment" => environment)
        end

        # The header without its ids (the run's, its key, its scope), times
        # (created_at, the override's at), actors (started_by, the
        # override's actor) and digest; the environment is kept, so a run
        # resumes only on the code it started on.
        def digest(header)
          body = header.except("tuning_run_id", "idempotency_key", "scope", "created_at", "started_by", "tuning_digest")
          split = body["split"]
          body["split"] = split.merge("override" => split["override"]&.slice("reason")) if split
          Evals::Identity.digest({ "format" => "smith.tuning.digest/1" }.merge(body))
        end

        # An iteration's line. parent: [Candidate, index] or nil;
        # minibatch: [sample ids, Evaluation::Pass] or nil; child:
        # {candidate:, index:, minibatch:} or nil; validation: a Pass or
        # nil; totals: the run's {metric_calls:, provider_calls:,
        # cost_nanos:, cost_complete:, reflection_calls:}, so a restored
        # loop can write the summary; rng: the run's SplitMix64;
        # cursor: Minibatches#cursor.
        def iteration(tuning_run_id:, iteration:, ended_as:, totals:, rng:, cursor:, parent: nil, component: nil,
                      minibatch: nil, child: nil, validation: nil)
          Parts.line(tuning_run_id, "iteration", iteration).merge(
            "parent" => parent && { "candidate_id" => parent.first.candidate_id, "index" => parent.last },
            "component" => component, "minibatch" => minibatch && Parts.minibatch(*minibatch),
            "ended_as" => ended_as.to_s, "child" => child && Parts.child(**child),
            "validation" => validation && Parts.pass(validation).merge("n" => validation.samples.size),
            "totals" => totals.transform_keys(&:to_s), "rng" => rng.to_hex, "cursor" => cursor
          )
        end

        # A reflection's line, from the seam's Reflection::Call: its reply
        # as {idea, instruction}, or its failure, and whether it stops the
        # run, so a restored loop decides as the first one did.
        def reflection(tuning_run_id:, iteration:, call:)
          reply = Reflection.reply(call.output) unless call.failure
          Parts.line(tuning_run_id, "reflection", iteration).merge(
            "trial_id" => call.trial_id, "step" => call.step,
            "output" => reply && { "idea" => reply.idea, "instruction" => reply.instruction },
            "failure" => call.failure || (REPLY_INVALID unless reply), "stop" => call.stop&.to_s
          )
        end

        # The summary. stop: {code:, detail:} or nil; seed and best:
        # [Candidate, index, mean] or nil; usage: {cost_nanos:,
        # cost_complete:, provider_calls:, reflection_calls:}.
        def summary(tuning_run_id:, scope:, revision:, status:, ended:, stop:, iterations:, candidates:,
                    metric_calls_used:, validation_passes:, usage:, seed:, best:, warnings: [])
          Parts.format_of(:summary).merge(
            "tuning_run_id" => tuning_run_id, "scope" => Smith::Scope.build(scope), "summary_revision" => revision,
            "status" => status.to_s, "ended" => ended&.to_s,
            "stop" => stop && { "code" => stop[:code].to_s, "detail" => stop[:detail] },
            "iterations" => iterations, "candidates" => candidates, "metric_calls_used" => metric_calls_used,
            "validation_passes" => validation_passes, "usage" => usage.transform_keys(&:to_s),
            "seed" => Parts.mark(seed), "best" => Parts.mark(best), "warnings" => warnings.map(&:to_s),
            "proposal" => nil
          )
        end
      end

      attr_reader :header, :lines, :summary

      # What a store holds: the header, every line in order, the summary or
      # nil.
      def initialize(header:, lines:, summary:)
        @header = header
        @lines = lines.freeze
        @summary = summary
        freeze
      end

      def tuning_run_id = header["tuning_run_id"]
      def iterations = lines.select { _1["type"] == "iteration" }
      def reflections = lines.select { _1["type"] == "reflection" }

      # Every candidate that joined the pool, in index order. O(L + C) for L
      # lines and C components a candidate.
      def candidates
        base = header["components"].to_h { [_1["id"], _1["base_version"]] }
        joined = iterations.select { _1.dig("child", "index") }.sort_by { _1.dig("child", "index") }
        joined.each_with_object([]) { |line, found| found << candidate(line, base, found) }
      end

      private

      def candidate(line, base, found)
        child, validation = line.values_at("child", "validation")
        parent = line.dig("parent", "index")
        texts, versions = lineage(child, parent ? found.fetch(parent) : nil, base)
        Candidate.new(index: child["index"], candidate_id: child["candidate_id"], parent:,
                      component: child["component"], idea: child["idea"], texts:, versions:,
                      scores: validation["scores"], mean: validation["mean"],
                      metric_calls: line.dig("totals", "metric_calls"))
      end

      # The parent's texts and versions with the child's change.
      def lineage(child, parent, base)
        texts = parent ? parent.texts : {}
        versions = parent ? parent.versions : base
        component = child["component"]
        return [texts.freeze, versions.freeze] unless component

        [texts.merge(component => child["text"]).freeze, versions.merge(component => child["version"]).freeze]
      end

      # Internal. The parts the builders share.
      module Parts
        module_function

        def format_of(kind) = { "format" => FORMATS.fetch(kind), "format_version" => FORMAT_VERSION }

        def line(tuning_run_id, type, iteration)
          format_of(:line).merge("tuning_run_id" => tuning_run_id, "type" => type, "iteration" => iteration)
        end

        # What the run measures with: the suite, its dataset, the subject and
        # the objective scorer's version.
        def measured(selection, objective)
          manifest = selection.manifest
          scorer = manifest["scorers"].find { _1["name"] == objective }
          raise ArgumentError, "objective names #{objective}, which the suite does not score" unless scorer

          { "suite" => { "name" => manifest["name"], "version" => manifest["version"],
                         "measure_digest" => selection.measure_digest },
            "dataset" => { "name" => selection.dataset.name, "version" => selection.dataset.version },
            "subject" => { "workflow" => manifest.dig("subject", "workflow") },
            "objective" => { "scorer" => objective, "scorer_version" => scorer["version"] } }
        end

        def pass(pass) = { "eval_run_id" => pass.eval_run_id, "scores" => pass.scores, "mean" => pass.mean }
        def minibatch(sample_ids, pass) = { "sample_ids" => sample_ids }.merge(pass(pass))

        def child(candidate:, index:, minibatch:)
          component = candidate.component
          { "candidate_id" => candidate.candidate_id, "index" => index, "component" => component,
            "version" => component && candidate.versions[component], "text" => component && candidate.texts[component],
            "idea" => candidate.idea, "minibatch" => minibatch && pass(minibatch) }
        end

        def mark(entry) = entry && { "candidate_id" => entry[0].candidate_id, "index" => entry[1], "mean" => entry[2] }
      end
      private_constant :Parts
    end
  end
end
