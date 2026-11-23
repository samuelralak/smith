# frozen_string_literal: true

require_relative "../error"

module Smith
  module Evals
    # Experimental. Every error evals raise on purpose (slice-1a design,
    # 4.11). Messages name fields, paths, ids and line numbers, never a
    # sample's content, so they are safe to log.
    class Error < Smith::Error; end

    # A suite that cannot be built: `problems` lists every "path: problem"
    # line found (at most MAX_PROBLEMS), each path a JSON Pointer into the
    # suite manifest or the DSL name of a setting the manifest leaves out.
    class SuiteInvalid < Error
      MAX_PROBLEMS = 100

      attr_reader :problems

      def initialize(problems, suite: nil)
        @problems = Array(problems).first(MAX_PROBLEMS).map { |line| String(line).dup.freeze }.freeze
        named = suite ? "suite #{suite}" : "the suite"
        super("#{named} is invalid: #{@problems.join("; ")}")
      end
    end

    # A dataset file, line or manifest that is not in its format.
    class DatasetInvalid < Error; end

    # A dataset whose content does not match its manifest, a suite's pin or
    # (on resume) a record's header. `parts` names what differs.
    class DatasetChanged < Error
      attr_reader :parts

      def initialize(message, parts: [])
        @parts = Array(parts).map { |part| String(part).dup.freeze }.freeze
        super(message)
      end
    end

    # A suite on the holdout or calibration split, which slice 1a refuses
    # until slice 2's use counter and reveal exist (design 13, question 1).
    class SplitNotAllowed < Error; end

    # The subject cannot run: its runtime readiness is :not_ready.
    class SubjectNotReady < Error; end

    # A driver whose form this runner cannot drive.
    class DriverUnsupported < Error; end

    # A start with a known id or key whose plan digest differs from the
    # record's. `fields` names what differs.
    class ResumeMismatch < Error
      attr_reader :fields

      def initialize(message, fields: [])
        @fields = Array(fields).map { |field| String(field).dup.freeze }.freeze
        super(message)
      end
    end

    # Another process holds the run's lease.
    class RunBusy < Error; end

    # A complete record line that does not parse.
    class RecordCorrupt < Error
      attr_reader :line

      def initialize(message, line:)
        @line = line
        super(message)
      end
    end

    # A store's I/O failed; `operation` names the store call.
    class StoreError < Error
      attr_reader :operation

      def initialize(message, operation:)
        @operation = operation
        super(message)
      end
    end
  end
end
