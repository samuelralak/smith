# frozen_string_literal: true

require_relative "../version"
require_relative "statistics"
require_relative "store/clock"

module Smith
  module Evals
    # Experimental; the record header, launch line, trial line and summary
    # (format 1) are frozen with slice 1a.5. One eval run's record as its
    # store keeps it (slice-1a design, 4.6; the contracts' record schemas):
    #
    #   record = Smith::Evals.record("er_...", scope: { tenant: "ten_0193" })
    #   record.header      # => Hash, written once when the run started
    #   record.segments    # => Array of Hash, one per launch
    #   record.each_trial  # => Enumerator of the effective trial lines
    #   record.summary     # => Hash, or nil while the run runs or was interrupted
    #
    # Each read goes to the store, so a running run reads as it stands.
    # The class methods build the header and a launch line.
    class Record
      HEADER = "smith.evals.record_header"
      SEGMENT = "smith.evals.segment"

      attr_reader :eval_run_id, :scope, :header

      # nil when the store holds no such run in the scope.
      def self.read(store:, scope:, eval_run_id:)
        header = store.read_header(scope:, eval_run_id:)
        header && new(store:, scope:, eval_run_id:, header:)
      end

      def initialize(store:, scope:, eval_run_id:, header:)
        @store = store
        @scope = scope
        @eval_run_id = eval_run_id
        @header = header
        freeze
      end

      def segments = @store.each_segment(scope:, eval_run_id:).to_a
      def summary = @store.read_summary(scope:, eval_run_id:)

      # Every trial line, superseded ones included, in append order.
      def each_line(&) = @store.each_trial(scope:, eval_run_id:, &)

      # The effective trial lines: each trial's highest trial_revision, in
      # the order they were appended. Two reads, keeping only each trial's
      # highest revision between them, so memory is O(T) for T trials; a
      # line appended after the first read is left out.
      def each_trial
        return enum_for(:each_trial) unless block_given?

        highest = revisions
        each_line { |line| yield line if highest[line["trial_id"]] == line["trial_revision"] }
      end

      private

      # Each trial's highest revision.
      def revisions
        highest = Hash.new(0)
        each_line { |line| highest[line["trial_id"]] = [highest[line["trial_id"]], line["trial_revision"]].max }
        highest
      end

      class << self
        # The header a start writes (contracts' record-header.schema.json).
        def header(plan, eval_run_id:, idempotency_key:, started_by:, created_at:, config:)
          { "format" => HEADER, "format_version" => 1, "eval_run_id" => eval_run_id, "scope" => plan.scope.to_h,
            "kind" => "eval", "created_at" => Store::Clock.timestamp(created_at), "started_by" => started_by&.to_h,
            "idempotency_key" => idempotency_key, **measured(plan), "subject" => subject(plan), "group" => nil,
            "candidate" => nil, "driver" => driver(plan.driver), "recording" => plan.recording.transform_keys(&:to_s),
            "statistics" => plan.manifest["statistics"].merge("stats_schema" => Statistics::SCHEMA),
            "environment" => environment(config), "cost_unit" => config.cost_unit,
            "per_sample_visibility" => "open" }
        end

        # A launch line: segment 1 starts the run, each later one resumes it.
        def segment(eval_run_id:, number:, started_by:, started_at:, already:, config:)
          purpose = number == 1 ? "start" : "resume"
          { "format" => SEGMENT, "format_version" => 1, "eval_run_id" => eval_run_id, "segment" => number,
            "started_at" => Store::Clock.timestamp(started_at), "started_by" => started_by&.to_h,
            "environment" => environment(config), "purpose" => purpose, "request_key" => nil,
            "resumed" => purpose == "resume", "trials_already_recorded" => already }
        end

        def environment(config)
          { "smith_version" => Smith::VERSION, "execution_semantics_version" => Smith::EXECUTION_SEMANTICS_VERSION,
            "ruby_version" => RUBY_VERSION, "host_code_version" => config.host_code_version }
        end

        private

        # What the run measures: the suite, the dataset, the selection, the plan.
        def measured(plan)
          manifest = plan.manifest
          { "suite" => { "name" => manifest["name"], "version" => manifest["version"],
                         "measure_digest" => plan.selection.measure_digest, "manifest" => manifest },
            "dataset" => dataset(plan.selection.dataset), "selection" => selection(plan), "plan" => planned(plan) }
        end

        def dataset(dataset)
          { "name" => dataset.name, "version" => dataset.version, "hashes" => dataset.hashes,
            "sample_count_total" => dataset.manifest.sample_count }
        end

        def selection(plan)
          { "split" => plan.split, "narrow" => plan.manifest.dig("selection", "narrow"),
            "sample_count" => plan.samples.size, "sample_ids_digest" => plan.selection.sample_ids_digest }
        end

        def planned(plan)
          { "trials_per_sample" => plan.trials_per_sample, "planned_trials" => plan.planned_trials,
            "order" => "trial_index_major", "concurrency" => plan.concurrency, "error_retries" => plan.error_retries,
            "max_cost_nanos" => plan.manifest.dig("budget", "max_cost_nanos"), "plan_digest" => plan.digest }
        end

        # A code workflow: its agents are empty by rule (the observed models
        # are in summary.models), its definition digest its class's own.
        def subject(plan)
          declared = plan.manifest["subject"]
          { "kind" => "workflow", "workflow" => declared["workflow"],
            "definition_digest" => plan.subject.workflow.definition_digest, "definition" => nil, "input" => nil,
            "until" => declared["until"], "keep" => declared["keep"], "version" => declared["version"],
            "agents" => [], "variant" => nil }
        end

        def driver(driver)
          { "name" => driver.class.name || driver.class.to_s, "form" => "in_process",
            "max_concurrency" => driver.max_concurrency, "isolation" => driver.isolation.to_s }
        end
      end
    end
  end
end

require_relative "record/trial_line"
