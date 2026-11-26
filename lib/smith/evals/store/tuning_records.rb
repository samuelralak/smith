# frozen_string_literal: true

require_relative "records"

module Smith
  module Evals
    module Store
      # Internal. A tuning run's records (slice 5a) as Smith's stores check
      # and keep them, by Records' rules and in its forms (a header and a
      # summary as indented documents, a line compact): a header filed by
      # its own id under its own scope, a line known by its type and
      # iteration, a summary by its revision. And the one run a lease or
      # cancel call names, by an eval run id or a tuning run id, with the
      # words and the lease keyword for its kind.
      module TuningRecords
        FORMATS = { header: "smith.tuning.header", line: "smith.tuning.line", summary: "smith.tuning.summary" }.freeze
        STATUSES = %w[running finished stopped cancelled failed].freeze
        LINE_TYPES = %w[reflection iteration].freeze

        module_function

        def tuning_run_id!(id)
          return id if id.is_a?(String) && Identity::TUNING_RUN_ID.match?(id)

          raise ArgumentError, "a tuning run id is tu_ and 32 lowercase hex digits"
        end

        def run_id!(eval_run_id, tuning_run_id)
          unless eval_run_id.nil? ^ tuning_run_id.nil?
            raise ArgumentError, "name one of eval_run_id: and tuning_run_id:"
          end

          eval_run_id.nil? ? tuning_run_id!(tuning_run_id) : Records.eval_run_id!(eval_run_id)
        end

        def run_name(id) = id.start_with?("tu_") ? "tuning run" : "eval run"
        def run_key(id) = id.start_with?("tu_") ? { tuning_run_id: id } : { eval_run_id: id }

        def header!(header, scope)
          Records.kept(header, :header) do |value|
            format!(value, :header)
            same_scope!(value, scope, "header")
            unless value["created_at"].is_a?(String) && Records::TIMESTAMP.match?(value["created_at"])
              raise ArgumentError, "the header's created_at is a UTC time such as 2026-11-21T07:30:03.725Z"
            end

            tuning_run_id!(value["tuning_run_id"])
          end
        end

        def line!(line, tuning_run_id)
          Records.kept(line, :tuning_line) do |value|
            owned!(value, :line, tuning_run_id)
            unless LINE_TYPES.include?(value["type"])
              raise ArgumentError, "a tuning line's type is reflection or iteration"
            end
            unless value["iteration"].is_a?(Integer) && value["iteration"] >= 0
              raise ArgumentError, "a tuning line's iteration is an Integer of at least 0"
            end

            value.values_at("type", "iteration")
          end
        end

        def summary!(summary, scope, tuning_run_id)
          Records.kept(summary, :summary) do |value|
            owned!(value, :summary, tuning_run_id)
            same_scope!(value, scope, "summary")
            unless STATUSES.include?(value["status"])
              raise ArgumentError, "a tuning summary's status is one of #{STATUSES.join(", ")}"
            end

            Records.positive!(value["summary_revision"], "a summary's summary_revision")
          end
        end

        def format!(value, kind)
          return if value["format"] == FORMATS[kind]

          raise ArgumentError, "a tuning #{kind}'s format is #{FORMATS[kind]}"
        end

        # A line or summary of this run, in its format.
        def owned!(value, kind, tuning_run_id)
          format!(value, kind)
          return if value["tuning_run_id"] == tuning_run_id

          raise ArgumentError, "a tuning #{kind}'s tuning_run_id is not #{tuning_run_id}"
        end

        def same_scope!(value, scope, what)
          return if Records.scope_of(value) == scope

          raise ArgumentError, "the #{what}'s scope is not the scope it is stored under"
        end
        private_class_method :format!, :owned!, :same_scope!
      end
    end
  end
end
