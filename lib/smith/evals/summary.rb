# frozen_string_literal: true

require "time"
require_relative "statistics"
require_relative "summary/tally"
require_relative "summary/results"

module Smith
  module Evals
    # Experimental; its format (smith.evals.summary, version 1, with
    # usage.by_model) is frozen with slice 1a.5. A run's summary (slice-1a
    # design, 6.4; contracts' summary.schema.json), built from its header,
    # launch lines and trial lines, and the selected samples' clusters (the
    # plan's: a record does not keep them), so a resumed run, a stored
    # record and the published examples give the same one.
    #
    # Each trial's result is its effective line (the highest
    # trial_revision); usage, counts and models count every line, superseded
    # ones and every attempt included, and are the subject's spend only
    # (judging, from slice 2, is counted apart). The trials that never
    # started count as not_run, under the stop's code. `status` and `stop`
    # are the runner's to say; `samples` are the selected samples (their
    # clusters). Gates are slice 1b.1's: `gates` is empty and `gate_result`
    # "none". One pass over the lines: O(L) time, O(T) memory for T trials,
    # plus the estimates (design 7.10).
    module Summary
      FORMAT = "smith.evals.summary"

      class << self
        def build(header:, segments:, lines:, samples:, status:, stop:, ended_at:, revision: 1, reruns: [])
          tally = Tally.new
          lines.each { tally.add(_1) }
          { "format" => FORMAT, "format_version" => 1, "eval_run_id" => header.fetch("eval_run_id"),
            "scope" => header.fetch("scope"), "summary_revision" => revision, "written_at" => ended_at,
            "status" => status.to_s, "stop" => stop, "complete" => status.to_s == "succeeded",
            **times(segments, ended_at), **figures(header, samples, tally, stop), "gates" => [],
            "gate_result" => "none", "warnings" => warnings(tally, segments), "reruns" => reruns,
            "per_sample_visibility" => header.fetch("per_sample_visibility") }
        end

        private

        def figures(header, samples, tally, stop)
          planned = planned(header)
          { "planned" => planned, **tally.outcomes(planned["trials"], stop), "retries" => tally.retries,
            "results" => Results.new(header, samples).call(tally.trials),
            "usage" => tally.usage(planned["trials_per_sample"]), "latency_ms" => tally.latency,
            "counts" => tally.counts, "models" => tally.models }
        end

        def times(segments, ended_at)
          started_at = segments.first.fetch("started_at")
          { "started_at" => started_at, "ended_at" => ended_at,
            "duration_ms" => ((Time.iso8601(ended_at).to_r - Time.iso8601(started_at).to_r) * 1000).floor,
            "segments" => segments.map do |segment|
              { "segment" => segment["segment"], "purpose" => segment["purpose"], "started_at" => segment["started_at"],
                "smith_version" => segment.dig("environment", "smith_version"),
                "host_code_version" => segment.dig("environment", "host_code_version") }
            end }
        end

        def planned(header)
          { "samples" => header.dig("selection", "sample_count"),
            "trials_per_sample" => header.dig("plan", "trials_per_sample"),
            "trials" => header.dig("plan", "planned_trials") }
        end

        # errors_present, unscored_present, resumed (the resumes) and
        # mixed_code_versions (the Smith and host code versions the launches
        # ran on, when more than one), each with its count.
        def warnings(tally, segments)
          resumes = segments.count { _1["purpose"] == "resume" }
          versions = segments.map { _1.fetch("environment").values_at("smith_version", "host_code_version") }.uniq
          [["errors_present", tally.count("error")], ["unscored_present", tally.count("unscored")],
           ["resumed", resumes], ["mixed_code_versions", versions.size > 1 ? versions.size : 0]]
            .select { _2.positive? }.map { |code, count| { "code" => code, "count" => count } }
        end
      end
    end
  end
end
