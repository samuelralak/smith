# frozen_string_literal: true

require_relative "../canonical_json"
require_relative "../diagnostic_text"
require_relative "../json_value"

module Smith
  module Evals
    # Experimental. What a scorer gives for one trial (slice-1a design,
    # 4.3): a pass or a fail (binary), a value from 0 to 1 (continuous), or
    # unscored when the grader could not decide. An explanation is cut at
    # 4 KiB (marked); a label over 256 bytes, metadata that is not a JSON
    # object of at most 4 KiB canonical, or a value outside 0 to 1 makes the
    # score unscored with reason score_invalid, never a pass or a fail.
    class Score
      MAX_EXPLANATION_BYTES = 4_096
      MAX_LABEL_BYTES = 256
      MAX_METADATA_BYTES = 4_096
      MAX_DETAIL_BYTES = 1_024

      attr_reader :status, :passed, :value, :scale, :label, :explanation, :metadata, :reason

      class << self
        def pass(explanation = nil, label: nil, metadata: nil) = binary(true, explanation, label:, metadata:)
        def fail(explanation = nil, label: nil, metadata: nil) = binary(false, explanation, label:, metadata:)

        # A pass when the two are equal after canonical JSON (so :billing
        # and "billing" are), explained as "matched billing" or "expected
        # billing, got shipping".
        def match(actual, expected, label: nil)
          same = CanonicalJSON.generate(actual) == CanonicalJSON.generate(expected)
          binary(same, same ? "matched #{shown(expected)}" : "expected #{shown(expected)}, got #{shown(actual)}",
                 label:, metadata: nil)
        rescue CanonicalJSON::Error
          invalid("the values compared have no JSON form")
        end

        def value(number, explanation: nil, label: nil, metadata: nil)
          unless number.is_a?(Numeric) && number.real? && number.to_f.finite? && number.between?(0, 1)
            return invalid("a value is a number from 0 to 1")
          end

          scored(:continuous, nil, number.to_f, explanation:, label:, metadata:)
        end

        # The grader could not decide (reason grader_undecided).
        def unscored(explanation = nil) = unscored_by("grader_undecided", explanation)

        # A score that broke a rule (reason score_invalid).
        def invalid(detail) = unscored_by("score_invalid", detail)

        # A scorer that raised (reason scorer_raised), named by the error's
        # class only: its message may quote what was scored.
        def raised(scorer_name, error)
          unscored_by("scorer_raised", "scorer #{scorer_name} raised #{DiagnosticText.error_class_name(error)}")
        end

        private

        def binary(passed, explanation, label:, metadata:)
          scored(:binary, passed, passed ? 1.0 : 0.0, explanation:, label:, metadata:)
        end

        def scored(scale, passed, value, explanation:, label:, metadata:)
          problem = Rules.problem(explanation, label, metadata)
          return invalid(problem) if problem

          new(status: :scored, scale:, passed:, value:, label: label.is_a?(Symbol) ? label.name : label,
              explanation: explanation && DiagnosticText.capture(explanation, max_bytes: MAX_EXPLANATION_BYTES),
              metadata: metadata && JSONValue.normalized(metadata), reason: nil)
        end

        def unscored_by(code, text)
          text = DiagnosticText.capture(text, max_bytes: MAX_EXPLANATION_BYTES) unless text.nil?
          detail = text && DiagnosticText.capture(text, max_bytes: MAX_DETAIL_BYTES)
          new(status: :unscored, scale: nil, passed: nil, value: nil, label: nil, explanation: text, metadata: nil,
              reason: { "code" => code, "by" => "grader", "detail" => detail }.freeze)
        end

        def shown(value)
          case value
          when nil then "nothing"
          when String then value
          when Symbol then value.name
          else CanonicalJSON.generate(value)
          end
        end
      end

      def initialize(status:, scale:, passed:, value:, label:, explanation:, metadata:, reason:)
        @status = status
        @scale = scale
        @passed = passed
        @value = value
        @label = label&.dup&.freeze
        @explanation = explanation
        @metadata = metadata
        @reason = reason
        freeze
      end
      private_class_method :new

      # The trial line's fields for this score (the record adds source and
      # scorer_version); a binary value is written 1 or 0.
      def to_h
        { "status" => status.name, "passed" => passed, "value" => scale == :binary ? value.to_i : value,
          "label" => label, "explanation" => explanation, "metadata" => metadata, "reason" => reason }
      end

      # The bounds a score keeps.
      module Rules
        module_function

        def problem(explanation, label, metadata)
          return "an explanation is a String" unless explanation.nil? || explanation.is_a?(String)
          return "a label is a String of at most #{MAX_LABEL_BYTES} bytes" unless label?(label)

          metadata_problem(metadata)
        end

        def label?(label)
          return true if label.nil?

          text = label.is_a?(Symbol) ? label.name : label
          JSONValue.utf8?(text) && text.bytesize <= MAX_LABEL_BYTES
        end

        def metadata_problem(metadata)
          return if metadata.nil?
          return "metadata is a JSON object" unless metadata.is_a?(Hash)
          return if CanonicalJSON.generate(metadata).bytesize <= MAX_METADATA_BYTES

          "metadata is at most #{MAX_METADATA_BYTES} bytes of canonical JSON"
        rescue CanonicalJSON::Error
          "metadata has no JSON form"
        end
      end
      private_constant :Rules
    end
  end
end
