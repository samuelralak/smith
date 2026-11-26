# frozen_string_literal: true

require_relative "../../diagnostic_text"
require_relative "../../interruptions"
require_relative "readings"

module Smith
  module Evals
    module Outcomes
      # How a subject's error reads (slice-1a design, 6.3), in order: an
      # error the host names in Smith.config.interrupting_errors (found in
      # its causes, as Smith finds it); a class the suite lists as its own
      # infrastructure (the error or one of its first CAUSE_DEPTH causes);
      # the run credential classes and a scrubbed error, by class; an
      # uncertain tool outcome or a plain WorkflowError with a cause, by that
      # cause; then Smith's failure family (Workflow::FailureRecord), a class
      # within it where the table says. The provider rows read the failure
      # kind the attempt seam recorded on the trial's steps, so nothing here
      # names the provider gem. Classes are named, and looked up only among
      # an error's ancestors, so a class not loaded (Smith::Testing's) is
      # never required. Internal. O(D + S) for D causes and S steps.
      class ErrorReading
        include Readings

        def initialize(steps:, infrastructure_errors:)
          @steps = steps
          @infrastructure = Array(infrastructure_errors)
        end

        # [outcome, code, by, retryable, stops_run, the error that decided].
        def call(error)
          return [*INFRASTRUCTURE.call("interrupted"), error] if Smith::Interruptions.find(error)
          return [*INFRASTRUCTURE.call("host_infrastructure"), error] if listed?(error)

          by_cause(error, CAUSE_DEPTH)
        end

        def self.family(error) = Smith::Workflow::FailureRecord.capture({ error: })[:error_family]

        private

        def listed?(error)
          causes(error).any? { |cause| @infrastructure.any? { cause.is_a?(_1) } }
        end

        def causes(error)
          found = []
          while error && found.length < CAUSE_DEPTH
            found << error
            error = error.cause
          end
          found
        end

        def by_cause(error, depth)
          known = by_class(error)
          return [*known, error] if known
          return by_cause(error.cause, depth - 1) if wrapper?(error) && depth.positive?

          [*by_family(error), error]
        end

        def by_class(error)
          if named?(error, "Smith::ProviderCredentialsRefused")
            code = REFUSALS[error.kind]
            return code && STOPPING.call(code)
          end

          CLASSES.find { |name, _| named?(error, name) }&.last
        end

        def wrapper?(error)
          return false if error.cause.nil?

          named?(error, "Smith::ToolOutcomeUncertain") || error.instance_of?(Smith::WorkflowError)
        end

        def by_family(error)
          family = self.class.family(error)
          return provider(error) if family == "provider_permanent_failure"

          reading = FAMILIES.fetch(family) { FAMILIES.fetch("other") }
          reading = reading.find { |name, _| name.nil? || named?(error, name) }.last if reading.first.is_a?(Array)
          reading == :agent_error ? agent_error : reading
        end

        # The kind the seam recorded on the trial's last failed attempt of
        # the error's model and provider.
        def provider(error)
          step = @steps.reverse.find do |record|
            record["outcome"] == "failed" && record["model"] == error.model_id &&
              (error.provider.nil? || record["provider"] == error.provider.to_s)
          end
          code = PROVIDER_KINDS[step&.dig("failure", "kind")]
          code ? STOPPING.call(code) : SUBJECT.call("provider_rejected_request")
        end

        def agent_error
          last = @steps.reverse.find { _1["outcome"] == "failed" }
          INFRASTRUCTURE.call(UNAVAILABLE.include?(last&.dig("failure",
                                                             "kind")) ? "provider_unavailable" : "agent_error")
        end

        def named?(error, name) = error.class.ancestors.any? { _1.name == name }
      end
    end
  end
end
