# frozen_string_literal: true

require_relative "agent"
require_relative "attribution"
require_relative "diagnostic_text"
require_relative "error"
require_relative "agent/provider_failure_handling"
require_relative "attempt_observation/transcript"

module Smith
  # The observation seam for evals: one process-wide observer slot, nil
  # unless one is installed. Experimental and internal. It lives under
  # Smith, never under a class a host subclasses, so none of its names can
  # shadow a host's own constants in a host's class body.
  #
  # Agent::ProviderCallTiming reads the slot once per provider attempt, where
  # every attempt is recorded beside its one :provider_call trace (a chat's
  # completion and an image's paint alike), and calls `observe` only when it
  # is set, so an app that installs nothing pays one read of a nil. `observe`
  # hands the observer one Attempt per provider attempt, and only inside a
  # trial's scope (Attribution::Context#trial). It never raises into the step:
  # an observer error is logged by class and dropped. Building one is
  # O(M + A + B) for the chat's messages (Transcript), O(I) for an image's
  # I bytes (their digest), and O(1) outside a trial.
  #
  # An Attempt is frozen only at its top: the Attempt, its Hashes and its
  # lists are frozen, but the strings, a parsed reply's Hash and a tool
  # call's arguments in its messages are the chat's own objects, which the
  # step goes on to use as its output, context and session. An observer must
  # not change what it is handed; it copies what it keeps before changing it.
  #
  # A candidate that a run's credentials pass over before its chat exists is
  # observed too (`skipped`, outcome :skipped), so an eval record never shows
  # a fallback's answer under the skipped model's name. So there is one
  # observation per :provider_call trace, plus one per skipped candidate,
  # which has no trace.
  module AttemptObservation # rubocop:disable Metrics/ModuleLength -- the seam is one module, its skip included
    Attempt = Data.define(:trial, :agent, :components, :attempt_id, :attempt_index, :outcome, :failure, :model,
                          :provider, :mode, :memo, :duration_ms, :tokens, :stop_reason, :messages, :sent_count,
                          :tool_call_names, :position)

    # Smith's own words for a refused key, account or model, so a provider's
    # body never reaches a record through them.
    FIXED_MESSAGES = {
      credentials_missing: "The run's credentials have no key for this provider.",
      key_refused: "The provider refused the API key.",
      out_of_credit: "The provider account is out of credit.",
      permission: "The provider refused access to this model."
    }.freeze
    MESSAGE_BYTES = 1024
    private_constant :FIXED_MESSAGES, :MESSAGE_BYTES

    # Smith's failure predicates (Agent::ProviderFailureHandling, which read
    # the error alone), read the way the attempt read them.
    module Failures
      extend Agent::ProviderFailureHandling

      # The order matters: the first that holds names the failure.
      KINDS = { key_refused: :key_refused?, out_of_credit: :provider_account_failure?,
                permission: :model_permission_failure?, model_unavailable: :model_unavailable?,
                unsupported_content: :unsupported_content?, transient: :transient_failure?,
                transport: :transport_failure? }.freeze

      class << self
        def outcome(error)
          return :completed if error.nil?

          provider_failure?(error) ? :failed : :aborted
        end

        def kind(error)
          return :credentials_missing if error.is_a?(Smith::ProviderCredentialsMissing)
          return :aborted unless provider_failure?(error) || unsupported_content?(error)

          KINDS.find { |_kind, predicate| send(predicate, error) }&.first || :rejected
        end

        private

        def key_refused?(error) = provider_account_failure?(error) && error.is_a?(::RubyLLM::UnauthorizedError)
      end
    end
    private_constant :Failures

    @observer = nil
    @lock = Mutex.new

    class << self
      attr_reader :observer

      # One observer per process. Installing another raises; installing the
      # same one again does nothing.
      def install(observer)
        raise ArgumentError, "an attempt observer answers attempt_finished" unless
          observer.respond_to?(:attempt_finished)

        @lock.synchronize do
          raise Smith::Error, "another attempt observer is installed" if @observer && !@observer.equal?(observer)

          @observer = observer
        end
      end

      def uninstall(observer)
        @lock.synchronize { @observer = nil if @observer.equal?(observer) }
      end

      # `chat` and `sent_count` for a chat's attempt (its messages, and how
      # many of them were sent); `request` for an image's (Smith::PaintInput:
      # its prompt and images, as sent), and `image`, the RubyLLM::Image the
      # provider answered, kept or not (a store that failed). An attempt that
      # failed before either existed has neither, and no messages. The
      # keywords are the recordings', passed through as they are.
      def observe(attempt, agent_class, chat: nil, sent_count: nil, request: nil, image: nil)
        trial = Attribution.current&.trial
        return unless trial

        observer = @observer
        return unless observer

        messages, sent = transcript(agent_class, chat, sent_count, request, image)
        observer.attempt_finished(observation(trial, attempt, agent_class, messages, sent))
      rescue StandardError => e
        report(e)
      end

      # A candidate of an agent's model chain that the run's credentials do
      # not cover, passed over before its chat was built: nothing was sent.
      # The same guard as `observe`, and it never raises into the step.
      def skipped(agent_class, model_reference, attempt_index, attempt_id:, provider:)
        trial = Attribution.current&.trial
        return unless trial

        observer = @observer
        return unless observer

        facts = { attempt_id:, attempt_index:, model: model_reference.model_id, provider: }
        observer.attempt_finished(passed_over(trial, agent_class, facts))
      rescue StandardError => e
        report(e)
      end

      private

      def passed_over(trial, agent_class, facts)
        failure = { kind: :credentials_missing, error_class: "Smith::ProviderCredentialsMissing",
                    message: FIXED_MESSAGES.fetch(:credentials_missing) }.freeze
        Attempt.new(trial:, agent: (agent_class.register_as || agent_class.name)&.to_s,
                    components: nil, **facts, outcome: :skipped, failure:, mode: :sync,
                    memo: false, duration_ms: nil, tokens: nil, stop_reason: nil, messages: [].freeze, sent_count: 0,
                    tool_call_names: [].freeze, position:)
      end

      def report(error)
        Smith.config.logger&.error("Smith attempt observer error: #{DiagnosticText.error_class_name(error)}")
      rescue StandardError
        nil
      end

      def observation(trial, attempt, agent_class, messages, sent)
        Attempt.new(trial:, agent: agent_name(attempt, agent_class), components: attempt.components,
                    **attempt_facts(attempt), messages:, sent_count: sent,
                    tool_call_names: tool_call_names(messages, sent), position:)
      end

      # [messages, how many of them were sent]. An image's request is one
      # entry, its settings and its image's media type as the agent declared
      # them (ImageRequest).
      def transcript(agent_class, chat, sent_count, request, image)
        if request
          [Transcript.painting(request.first, ImageRequest.declared(agent_class), image,
                               ImageRequest.media_type(agent_class)), 1]
        elsif chat.respond_to?(:messages)
          [Transcript.messages(chat.messages), sent_count || 0]
        else
          [[].freeze, 0]
        end
      end

      def attempt_facts(attempt)
        usage = attempt.usage
        reference = attempt.model_reference
        { attempt_id: attempt.attempt_id, attempt_index: attempt.attempt_index,
          outcome: Failures.outcome(attempt.error), failure: failure(attempt.error), model: reference.model_id,
          provider: reference.provider, mode: usage&.mode || :sync, memo: attempt.memo == true,
          duration_ms: attempt.duration_ms, tokens: tokens(usage), stop_reason: usage&.stop_reason }
      end

      def agent_name(attempt, agent_class) = (attempt.agent_name || agent_class.name)&.to_s

      def failure(error)
        return if error.nil?

        kind = Failures.kind(error)
        message = FIXED_MESSAGES.fetch(kind) { DiagnosticText.capture(error.message, max_bytes: MESSAGE_BYTES) }
        { kind:, error_class: DiagnosticText.error_class_name(error), message: }.freeze
      end

      def tokens(usage)
        return if usage.nil?

        { input: usage.input_tokens, output: usage.output_tokens, cache_read: usage.cache_read_tokens,
          cache_write: usage.cache_write_tokens, thinking: usage.thinking_tokens }.freeze
      end

      def tool_call_names(messages, sent)
        messages.drop(sent).flat_map { |entry| Array(entry["tool_calls"]).map { _1["name"] } }.freeze
      end

      def position
        context = Attribution.current
        { execution_key: context.execution_key, workflow: context.workflow, transition: context.transition,
          branch_key: context.branch_key, round: context.round }.freeze
      end
    end
  end
end
