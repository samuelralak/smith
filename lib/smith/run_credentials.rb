# frozen_string_literal: true

require "securerandom"
require_relative "attempt_observation"
require_relative "diagnostic_text"
require_relative "errors"
require_relative "provider_credentials"
require_relative "provider_credentials_scrubber"
require_relative "provider_options"
require_relative "scope"

module Smith
  # A credentialed run's hold on its provider credentials (additions design,
  # section 3): the scope its class's `provider_credentials` block is asked
  # with, and what the block answered, in memory only. The workflow keeps it
  # (and hands it to its nested workflows), so every branch and attempt of
  # the run reaches it without a thread-local.
  #
  # The block is asked at the run's first provider attempt in a process,
  # once (under a lock, however many branches ask), and again only after a
  # provider refuses the key (HTTP 401). Its answer becomes one RubyLLM
  # context (ProviderOptions.context) every attempt's chat is built on. Each
  # error an attempt meets is scrubbed before Smith does anything else with
  # it (`scrubbed`). Printed without its credentials, never serialized.
  # Loaded by a workflow class that declares `provider_credentials`.
  class RunCredentials
    # The run's scope: the declared keys, checked as Smith::Scope keys are,
    # and the values they have in a run's trusted context, kept with the run.
    module Scoping
      module_function

      def keys!(keys)
        raise ArgumentError, "provider_credentials scope keys must be Symbols" unless keys.all?(Symbol)
        raise ArgumentError, "provider_credentials takes at most #{Scope::MAX_PAIRS} scope keys" if
          keys.uniq.length > Scope::MAX_PAIRS

        keys.each do |key|
          raise ArgumentError, "provider_credentials scope key #{key.inspect} is not a scope key" unless
            key.name.match?(Scope::KEY)
        end
        keys.uniq.freeze
      end

      # A new run's binding: its scope from the declared keys of its trusted
      # context.
      def capture(workflow_class, context, untrusted)
        values = Budget::HostLedger.trusted_scope(workflow_class.smith_provider_credentials_scope_keys, context,
                                                  untrusted, "provider_credentials") { |_key, value| value }
        RunCredentials.new(workflow_class.provider_credentials, Scope.build(values))
      end

      # A nested class's scope never comes from the key its items are given
      # (item_to): item data, a model's answer perhaps, would choose it.
      def not_item!(workflow_class, key)
        return unless workflow_class.smith_provider_credentials_scope_keys.include?(key.to_sym)

        raise WorkflowError, "#{workflow_class} takes its provider_credentials scope from #{key.inspect}, the key " \
                             "its nested items are given (item_to), which item data cannot choose"
      end

      # A restored run's binding: its saved scope, or, for a run saved before
      # its class declared these keys, the one its context gives now.
      def restored(workflow_class, stored, context, untrusted)
        keys = workflow_class.smith_provider_credentials_scope_keys
        return capture(workflow_class, context, untrusted) unless
          stored.is_a?(Hash) && Budget::HostLedger.same_keys?(keys, stored)

        RunCredentials.new(workflow_class.provider_credentials, Scope.build(stored))
      rescue ScopeInvalid
        raise SerializationError, "persisted workflow provider_credentials_scope is invalid"
      end
    end

    # The block's answer: credentials or nil. Whatever else it gives, or
    # raises, is a ProviderCredentialsError with no cause, naming only the
    # class, or the refusal of Smith's own check, which names options and
    # fields, never values.
    module Block
      module_function

      def answer(builder, scope)
        answer = builder.call(scope)
        return answer if answer.nil? || answer.is_a?(ProviderCredentials)

        raise ProviderCredentialsError, "the provider_credentials block must return a Smith::ProviderCredentials " \
                                        "or nil, not #{/\A[AEIOU]/.match?(answer.class.name.to_s) ? "an" : "a"} " \
                                        "#{answer.class}"
      rescue ProviderCredentialsError
        raise
      rescue ProviderOptions::Invalid => e
        raise ProviderCredentialsError, "the provider_credentials block's credentials were refused: #{e.message}",
              cause: nil
      rescue StandardError => e
        raise ProviderCredentialsError, "the provider_credentials block raised #{DiagnosticText.error_class_name(e)}",
              cause: nil
      end
    end
    private_constant :Block

    attr_reader :scope

    def initialize(builder, scope)
      @builder = builder
      @scope = scope
      @lock = Mutex.new
      @resolved = false
      @credentials = nil
      @context = nil
      @scrubber = ProviderCredentialsScrubber.new([])
    end

    # The indexes of an agent's model chain the run's credentials do not
    # cover (ProviderCandidateSequence passes them over). A model whose
    # provider the registry does not name is attempted, and fails as a model
    # that is not there, as without credentials; the run's context holds no
    # other key. Asks the block if it has not been; raises before anything is
    # sent when the agent would replace the run's context, or the block gave
    # no credentials.
    def passed_over(agent_class, references)
      check_agent!(agent_class)
      credentials = resolved.first
      raise ProviderCredentialsMissing, "the run's provider_credentials block returned no credentials" unless
        credentials

      references.each_index.reject do |index|
        provider = provider_of(references[index])
        provider.nil? || credentials.covers?(provider)
      end
    end

    # Raised when every candidate of the chain was passed over.
    def none_covered!(references)
      providers = references.map { provider_of(_1) }.uniq
      raise ProviderCredentialsMissing.new("the run's credentials cover none of #{providers.join(", ")}",
                                           model_id: references.first.model_id)
    end

    # A passed-over candidate, observed as skipped: it has no trace, so its
    # id is its own, drawn whether or not anything observes it.
    def skipped(agent_class, reference, index)
      attempt_id = SecureRandom.uuid
      return unless AttemptObservation.observer

      AttemptObservation.skipped(agent_class, reference, index, attempt_id:, provider: provider_of(reference))
    end

    # What an attempt's chat is built with: the run's RubyLLM context.
    def chat_options = { context: context! }

    def ruby_llm_config = context!.config

    # What the run's batch requests are queued with (batch_queue.enqueue):
    # its scope, so the host submits them on that scope's credentials.
    def queued = { credentials_scope: @scope }

    # The error as Smith takes it in a credentialed attempt, before anything
    # else reads it (ProviderCredentialsScrubber#scrubbed). A 401 drops what
    # the block answered, so the run's next attempt asks it again. A scrub
    # that fails gives a ScrubbedError naming the class alone, so nothing
    # raised from it carries the original as its cause.
    def scrubbed(error)
      @scrubber.scrubbed(error).tap { drop! if ProviderOptions.refusal_kind(_1) == :key_refused }
    rescue StandardError
      ScrubbedError.new("#{error.class.name} could not be scrubbed, so nothing it said is kept",
                        original_class: error.class.name)
    end

    # The step's error for a refused key, credit or model: Smith's own text,
    # naming the provider, never the provider's.
    def refusal(error, model_reference)
      kind = ProviderOptions.refusal_kind(error)
      return unless kind

      facts = { provider: model_reference.provider, model_id: model_reference.model_id,
                source_error_class: error.class.name }
      return ProviderCredentialsRefused.new(kind:, **facts) unless kind == :out_of_credit

      ProviderPermanentFailure.new("#{model_reference.provider || "the provider"} reports the account is out of " \
                                   "credit (HTTP 402)", **facts)
    end

    def inspect = "#<#{self.class.name}>"
    alias to_s inspect

    def pretty_print(printer) = printer.text(inspect)

    %i[to_h to_json as_json encode_with marshal_dump _dump].each do |name|
      define_method(name) { |*| raise SecretSerializationError }
    end

    private

    def check_agent!(agent_class)
      if agent_class.respond_to?(:context) && agent_class.context
        raise WorkflowError, "#{agent_class} sets its own RubyLLM context, which would replace the run's credentials"
      end
      return unless agent_class.respond_to?(:inputs) && Array(agent_class.inputs).include?(:context)

      raise WorkflowError, "#{agent_class} declares an input named context, which the run's credentials need"
    end

    def provider_of(reference) = reference.provider || ProviderOptions.provider_of(reference.model_id)

    def context!
      resolved.last || raise(ProviderCredentialsMissing, "the run's provider_credentials block returned no credentials")
    end

    # [credentials, context], asking the block once.
    def resolved
      @lock.synchronize do
        unless @resolved
          @credentials = Block.answer(@builder, @scope)
          @context = @credentials && ProviderOptions.context(@credentials.ruby_llm_settings,
                                                             instrumenter: keep_instrumenter?)
          @scrubber = @scrubber.with(@credentials.secret_values) if @credentials
          @resolved = true
        end
        [@credentials, @context]
      end
    end

    def drop!
      @lock.synchronize do
        @resolved = false
        @credentials = nil
        @context = nil
      end
    end

    def keep_instrumenter?
      Smith.config.run_credentials_instrumenter == :keep && !Smith.config.require_run_credentials
    end
  end
end
