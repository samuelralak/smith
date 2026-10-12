# frozen_string_literal: true

module Smith
  # The errors a host names in Smith.config.interrupting_errors: the host
  # could not do its part (its database or queue out of reach), so the step
  # did not go wrong, it was cut short. A step that meets one stops where it
  # is, as if its worker had stopped. Smith takes no failure route, makes no
  # retry, records no failure and notifies no tool failure handler; the
  # error reaches the caller of advance!, run!, resume! or expire_wait! as it
  # was raised, even when Smith or the host wrapped it in another error on
  # the way (its `cause`). Smith does not count interruptions: a step that
  # meets one every time is the host's to bound. A persisted run's state is as the step left it: a
  # lax run takes the step again when it is next advanced, a strict run
  # finds it under way.
  module Interruptions
    CAUSE_DEPTH = 16

    module_function

    # The interrupting error that `error` is, or was raised from, or nil:
    # the error, or one of its first CAUSE_DEPTH - 1 causes (so a chain of
    # causes that loops ends too). A provider's own failure (RubyLLM's, or
    # its HTTP client's) is the provider's, whatever it was raised from: it
    # interrupts only when its own class is named.
    def find(error)
      classes = Smith.config.interrupting_errors
      return nil if classes.empty?

      current = error
      CAUSE_DEPTH.times do
        return nil if current.nil?
        return current if classes.any? { current.is_a?(_1) }
        return nil if provider_failure?(current)

        current = current.cause
      end
      nil
    end

    def provider_failure?(error)
      error.is_a?(RubyLLM::Error) || (defined?(Faraday::Error) && error.is_a?(Faraday::Error))
    end

    # Raises the interrupting error `error` is or was raised from, if any.
    def pass!(error)
      interruption = find(error)
      raise interruption, cause: interruption.cause if interruption
    end
  end
end
