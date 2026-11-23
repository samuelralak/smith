# frozen_string_literal: true

require "securerandom"

module Smith
  # An image agent's attempt (ImageRequest): its chat is built as any
  # attempt's is (instructions, inputs, content parts), then painted from
  # instead of completed (PaintInput). The request's options go as
  # its params, the size among them, since the provider gem's edit payload
  # sends its params and not its size.
  #
  # Each request is sent once: the chat's config is copied with no HTTP
  # retries, so a provider that billed a request is never asked for it
  # again behind Smith's back, and only a refusal or a throttle goes again
  # (Agent::ProviderFailureHandling). A moderation block is a refused
  # response, which costs nothing and goes to the agent's on_refusal
  # (OutputRefused by default). A request sent whose answer never came (a
  # read timeout, a connection lost; Providers::RequestOutcome) raises
  # RequestOutcomeUncertain, which no retry or fallback takes up. The image
  # is kept in the run's artifacts and answered as a content part. A paint
  # keeps no response memo (an image is too large to keep twice), so a step
  # a crash replays paints again: a host that pays for images runs in strict
  # idempotency, where such a step fails instead.
  #
  # Made for each attempt (ProviderPaint) rather than mixed into the
  # workflow, so a host's workflow gains none of its names. The workflow's
  # own steps it takes by name, as the attempt always has, a host's
  # definition of one among them.
  class ImageAttempt
    def initialize(workflow, agent_class)
      @workflow = workflow
      @agent_class = agent_class
    end

    # Every attempt of an image agent, a refusal's fallback included.
    def call(prepared_input, model_reference, attempt_index:)
      check_image_agent!
      @facts = { attempt_id: SecureRandom.uuid, attempt_index:, agent_name: @agent_class.register_as }
      painting_attempt(prepared_input, model_reference)
    end

    private

    def workflow(name, ...) = @workflow.__send__(name, ...)

    def check_image_agent!
      refused = image_refusals.select { |_, given| given }.keys
      return if refused.empty?

      raise WorkflowError, "#{@agent_class} answers with an image, which takes no #{refused.join(", ")}"
    end

    def image_refusals
      {
        "tools" => !Array(@agent_class.tools).empty?,
        "an output schema" => !(@agent_class.output_schema || @agent_class.schema || @agent_class.output_contract).nil?,
        "thinking" => !@agent_class.thinking.nil?,
        "a streamed step" => !@workflow.instance_variable_get(:@step_stream).nil?,
        "a batch" => @workflow.instance_variable_get(:@batch_capturing) == true
      }
    end

    # The paint's input (PaintInput: its prompt and images) is read once and
    # handed on as it was sent, to the paint and to the attempt's record.
    # The image the provider answered reaches the record through a local
    # that ends with this attempt, kept or not, so nothing holds it longer
    # than 0.16.0 does (its completion holds the kept image's ref alone).
    def painting_attempt(prepared_input, model_reference)
      chat = painting_chat(prepared_input, model_reference)
      observed = workflow(:observed_model_reference, chat, fallback: model_reference)
      timer = Agent::ProviderCallTiming::Timer.start
      sent = PaintInput.of(chat.messages)
      image = nil
      completion = painted(chat, sent, observed) { image = _1 }
      workflow(:completed_provider_attempt, completion, observed, timer.stop, @facts,
               agent_class: @agent_class, request: sent, image:)
    rescue StandardError => e
      failed_paint(e, observed || model_reference, timer&.stop, sent, image)
    end

    # A paint's failure traced as any attempt's: one whose outcome is
    # uncertain is raised as RequestOutcomeUncertain, its cause the
    # transport's error; an image that was drawn and billed but could not be
    # kept has its usage recorded before its error goes on. The paint's
    # input and the image (one that came back and could not be kept) are
    # passed as they are, for the attempt's record.
    def failed_paint(error, model_reference, timer, sent, image)
      usages, error = PaintedAnswer.unkept(error)
      workflow(:record_billed_usages, @agent_class, usages, :partial_attempt, model_reference,
               attempt_id: @facts[:attempt_id])
      error = outcome_uncertain(error) if Providers::RequestOutcome.uncertain?(error)
      attempt = workflow(:failed_provider_attempt, error, model_reference, timer, @facts, usages,
                         agent_class: @agent_class, request: sent, image:)
      raise error unless workflow(:provider_failure?, error) || workflow(:unsupported_content?, error)

      attempt
    end

    def painting_chat(prepared_input, model_reference)
      chat = @agent_class.chat(**model_reference.chat_options, **workflow(:bridge_workflow_inputs, @agent_class))
      sendable = chat.respond_to?(:with_context) && chat.respond_to?(:with_model)
      chat = workflow(:sent_once, chat, @agent_class) if sendable
      provider = workflow(:observed_model_reference, chat, fallback: model_reference).provider
      workflow(:add_prepared_input, chat, prepared_input, provider,
               Agent::ProviderRequest::Shape.new(output_schema: nil, output_limit: nil, prompt_cache: :none))
      chat
    end

    # Yields the provider's image before it is kept, for the attempt's
    # record (painting_attempt). A moderation block is a refusal
    # (ProviderPaint.refused?).
    def painted(chat, sent, model_reference)
      prompt, images = sent
      request = ImageRequest.declared(@agent_class)
      provider = workflow(:chat_provider, chat)
      image = held_paint(provider) do
        provider.paint(prompt, model: model_reference.model_id, size: request.fetch(:size),
                               with: images.empty? ? nil : images, params: request)
      end
      yield image
      PaintedAnswer.painted_completion(@agent_class, image)
    rescue StandardError => e
      raise unless ProviderPaint.refused?(e)

      PaintedAnswer.refused_completion
    end

    def held_paint(provider, &paint)
      ledger = workflow(:run_budget_ledger)
      return paint.call unless ledger

      Providers::RequestHolds.within(provider, ledger, @facts[:attempt_id], &paint)
    end

    # Raised inside the transport error's rescue, so it is the cause.
    def outcome_uncertain(error)
      raise RequestOutcomeUncertain,
            "the request was sent and no answer came (#{error.class}); it may have been billed"
    rescue RequestOutcomeUncertain => e
      e
    end
  end
end
