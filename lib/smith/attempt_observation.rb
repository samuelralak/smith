# frozen_string_literal: true

require "json"
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
  #
  # `started` is when the attempt's timed provider call started, on the
  # monotonic clock its duration is measured on (nil when no call started),
  # so a recorder places it on its trial's time line. `responses` are the
  # token counts and mode of each provider response the attempt's usage
  # entries record, one each (`tokens` is their sum), so a recorder prices
  # each response as the budget ledger does. `settings` is what its last
  # request carried, read from the request as it was sent (Settings).
  module AttemptObservation # rubocop:disable Metrics/ModuleLength -- the seam is one module, its skip included
    Attempt = Data.define(:trial, :agent, :components, :attempt_id, :attempt_index, :outcome, :failure, :model,
                          :provider, :mode, :memo, :duration_ms, :tokens, :responses, :stop_reason, :messages,
                          :sent_count, :tool_call_names, :position, :started, :settings)

    # Smith's own words for a missing or refused key, account or model, by
    # failure kind, so a provider's body never reaches an observation, or a
    # record, through them: an eval record's step, trial and attempt
    # messages use these (Smith::Evals). Frozen text: changing a word
    # changes every record that holds it.
    FIXED_MESSAGES = {
      credentials_missing: "no key for this provider",
      key_refused: "the provider refused the key (HTTP 401)",
      out_of_credit: "the provider reports no credit",
      permission: "the key has no permission for this model (HTTP 403)"
    }.freeze
    MESSAGE_BYTES = 1024
    private_constant :MESSAGE_BYTES

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

    # What a chat's request carried, read from the request itself where it
    # left for its provider (Sending), so it is what the provider was sent:
    # its temperature, output limit and thinking (an effort, a budget or
    # both), its params merged in and whatever RubyLLM's renderer left out
    # left out, each nil where the request carried none (the provider's own
    # default). A provider carries them under its own names (PATHS; one of
    # RubyLLM's OpenAI-compatible providers as OpenAI, Vertex AI as Gemini);
    # one not listed has none read. A key the params give as a String beside
    # RubyLLM's Symbol is read first: json 2 writes both, the String last,
    # and a provider reads the last. A request that never left (a stub's
    # answer, a response memo's, a call that failed before it, one JSON could
    # not write, as json 3 refuses such a key twice) leaves none. Only read,
    # and kept by the request's provider object (its chat's alone) in a weak
    # map the seam holds, so a provider gone takes its entry with it; each
    # distinct reading is kept once (READINGS, at most MAX_READINGS), since a
    # weak map's values are weak too. O(1).
    module Settings
      NONE = { temperature: nil, max_output_tokens: nil, thinking: nil }.freeze
      # A request these stop was never written out, so it never left.
      UNWRITTEN = [JSON::GeneratorError, JSON::NestingError, EncodingError].freeze
      MAX_READINGS = 4_096
      OPENAI_LIMITS = [%i[max_output_tokens], %i[max_completion_tokens], %i[max_tokens]].freeze
      PATHS = {
        "anthropic" => { temperature: [%i[temperature]], max_output_tokens: [%i[max_tokens]],
                         effort: [%i[output_config effort]], budget: [%i[thinking budget_tokens]] },
        "openai" => { temperature: [%i[temperature]], max_output_tokens: OPENAI_LIMITS,
                      effort: [%i[reasoning_effort], %i[reasoning effort]], budget: [] },
        "openrouter" => { temperature: [%i[temperature]], max_output_tokens: OPENAI_LIMITS,
                          effort: [%i[reasoning effort]], budget: [%i[reasoning max_tokens]] },
        "gemini" => { temperature: [%i[generationConfig temperature]],
                      max_output_tokens: [%i[generationConfig maxOutputTokens]],
                      effort: [%i[generationConfig thinkingConfig thinkingLevel]],
                      budget: [%i[generationConfig thinkingConfig thinkingBudget]] },
        "bedrock" => { temperature: [%i[inferenceConfig temperature]],
                       max_output_tokens: [%i[inferenceConfig maxTokens]],
                       effort: [%i[additionalModelRequestFields reasoning_config reasoning_effort],
                                %i[additionalModelRequestFields reasoning_effort]],
                       budget: [%i[additionalModelRequestFields reasoning_config budget_tokens]] }
      }.freeze

      @sent = ObjectSpace::WeakMap.new
      @readings = {}
      @lock = Mutex.new

      module_function

      def keep(provider, payload)
        reading = read(provider, payload)
        @lock.synchronize do
          @readings[reading] ||= reading if @readings.size < MAX_READINGS
          @sent[provider] = @readings.fetch(reading, reading)
        end
      end

      # What the chat's last request carried, or NONE.
      def of(chat)
        chat = chat.to_llm if chat.respond_to?(:to_llm)
        provider = chat.instance_variable_get(:@provider) unless chat.nil?
        (@lock.synchronize { @sent[provider] } unless provider.nil?) || NONE
      end

      def read(provider, payload)
        paths = paths(provider.class)
        return NONE unless paths && payload.is_a?(Hash)

        effort, budget = paths.values_at(:effort, :budget).map { found(payload, _1) }
        thinking = { effort: copied(effort), budget: }.compact
        { temperature: found(payload, paths[:temperature]),
          max_output_tokens: found(payload, paths[:max_output_tokens]),
          thinking: thinking.empty? ? nil : thinking.freeze }.freeze
      end

      # The names of the first class in the provider's line that PATHS lists.
      def paths(klass)
        while klass.respond_to?(:slug)
          return PATHS[klass.slug] if klass.name && PATHS.key?(klass.slug)

          klass = klass.superclass
        end
      end

      def found(payload, paths) = paths.lazy.filter_map { dig(payload, _1) }.first

      def dig(payload, path)
        path.reduce(payload) do |level, key|
          break unless level.is_a?(Hash)

          level.key?(key.to_s) ? level[key.to_s] : level[key]
        end
      end

      # A String is the request's own: the observation keeps a frozen copy.
      def copied(value) = value.is_a?(String) ? value.dup.freeze : value
    end
    private_constant :Settings

    # A usage's token counts; and each response's, with its mode, as its
    # usage entry prices it.
    module Tokens
      module_function

      def of(usage)
        return if usage.nil?

        { input: usage.input_tokens, output: usage.output_tokens, cache_read: usage.cache_read_tokens,
          cache_write: usage.cache_write_tokens, thinking: usage.thinking_tokens,
          image_input: usage.image_input_tokens, image_output: usage.image_output_tokens }.freeze
      end

      def responses(usages) = Array(usages).map { { tokens: of(_1), mode: _1.mode || :sync }.freeze }.freeze
    end
    private_constant :Tokens

    # Prepended on RubyLLM::Connection once an observer is installed
    # (`install`), so an app that installs none sends as ever: every
    # provider request leaves through `post` with its payload as sent (each
    # round of a tool loop, a stream, Bedrock's signed request, Smith's
    # OpenAI Responses route). It passes what it is given on untouched, and
    # once the request has left (answered or not; not one JSON could not
    # write) hands its payload to `sending`, which never raises. The one
    # exception to "no RubyLLM internals" (slice-1a design, section 18):
    # 1.16's request path, pinned by the contract spec, and replaced at the
    # 2.x move by RubyLLM's public request seam (`chat.render`, or a
    # `before_request` callback).
    module Sending
      def post(*args, **, &)
        return super unless AttemptObservation.observer

        left = true
        begin
          super
        rescue *Settings::UNWRITTEN
          left = false
          raise
        ensure
          AttemptObservation.sending(self, args[1]) if left
        end
      end
    end
    private_constant :Sending

    @observer = nil
    @lock = Mutex.new

    class << self
      attr_reader :observer

      # One observer per process. Installing another raises; installing the
      # same one again does nothing. The first installed has RubyLLM's
      # requests read from then on (Sending).
      def install(observer)
        raise ArgumentError, "an attempt observer answers attempt_finished" unless
          observer.respond_to?(:attempt_finished)

        @lock.synchronize do
          raise Smith::Error, "another attempt observer is installed" if @observer && !@observer.equal?(observer)

          @observer = observer
          ::RubyLLM::Connection.prepend(Sending) unless ::RubyLLM::Connection <= Sending
        end
      end

      def uninstall(observer)
        @lock.synchronize { @observer = nil if @observer.equal?(observer) }
      end

      # `chat` and `sent_count` for a chat's attempt (its messages, and how
      # many of them were sent); `request` for an image's (Smith::PaintInput:
      # its prompt and images, as sent), and `image`, the RubyLLM::Image the
      # provider answered, kept or not (a store that failed). An attempt that
      # failed before either existed has neither, and no messages. `timer`
      # timed its provider call (nil when none started); `usages` are the
      # Agent::ProviderUsage of each response its usage entries record. The
      # keywords are the recordings', passed through as they are.
      def observe(attempt, agent_class, chat: nil, sent_count: nil, request: nil, image: nil, timer: nil, usages: [])
        trial = Attribution.current&.trial
        return unless trial

        observer = @observer
        return unless observer

        observer.attempt_finished(observation(trial, attempt, agent_class,
                                              transcript(agent_class, chat, sent_count, request, image),
                                              started: timer&.started_at, responses: Tokens.responses(usages),
                                              settings: Settings.of(chat)))
      rescue StandardError => e
        report(e)
      end

      # A request that left through `connection` (a RubyLLM::Connection)
      # with `payload` (Sending; a batch delivery, Providers::BatchExchange):
      # inside a trial, what it carried is kept for its attempt's
      # observation; one it cannot read is kept as none. It never raises.
      def sending(connection, payload)
        Settings.keep(connection.provider, payload) if Attribution.current&.trial
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
                    memo: false, duration_ms: nil, tokens: nil, responses: [].freeze, stop_reason: nil,
                    messages: [].freeze, sent_count: 0, tool_call_names: [].freeze, position:, started: nil,
                    settings: Settings::NONE)
      end

      def report(error)
        Smith.config.logger&.error("Smith attempt observer error: #{DiagnosticText.error_class_name(error)}")
      rescue StandardError
        nil
      end

      def observation(trial, attempt, agent_class, transcript, **read)
        messages, sent = transcript
        Attempt.new(trial:, agent: agent_name(attempt, agent_class), components: attempt.components,
                    **attempt_facts(attempt), messages:, sent_count: sent,
                    tool_call_names: tool_call_names(messages, sent), position:, **read)
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
          duration_ms: attempt.duration_ms, tokens: Tokens.of(usage), stop_reason: usage&.stop_reason }
      end

      def agent_name(attempt, agent_class) = (attempt.agent_name || agent_class.name)&.to_s

      def failure(error)
        return if error.nil?

        kind = Failures.kind(error)
        message = FIXED_MESSAGES.fetch(kind) { DiagnosticText.capture(error.message, max_bytes: MESSAGE_BYTES) }
        { kind:, error_class: DiagnosticText.error_class_name(error), message: }.freeze
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
