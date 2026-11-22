# frozen_string_literal: true

require_relative "paint_input"
require_relative "painted_answer"

module Smith
  class Agent
    # An image agent's attempt (ImageRequest): its chat is built as any
    # attempt's is (instructions, inputs, content parts), then painted from
    # instead of completed (PaintInput). The request's options go as its
    # params, the size among them, since RubyLLM's edit payload sends its
    # params and not its size.
    #
    # Each request is sent once: the chat's config is copied with no HTTP
    # retries, so a provider that billed a request is never asked for it
    # again behind Smith's back, and only a refusal or a throttle goes again
    # (ProviderFailureHandling). A moderation block is a refused response,
    # which costs nothing and goes to the agent's on_refusal (OutputRefused
    # by default). A request sent whose answer never came (a read timeout, a
    # connection lost; Providers::RequestOutcome) raises
    # RequestOutcomeUncertain, which no retry or fallback takes up. The
    # image is kept in the run's artifacts and answered as a content part.
    # A paint keeps no response memo (an image is too large to keep twice),
    # so a step a crash replays paints again: a host that pays for images
    # runs in strict idempotency, where such a step fails instead.
    module ProviderPaint
      include PaintedAnswer

      private

      # Every attempt an image agent makes (a candidate, a refusal's fallback,
      # a retry) paints; any other agent's completes (ProviderCompletion).
      def attempt_model(agent_class, prepared_input, model_reference, shape:, attempt_index:)
        return super unless agent_class.image_request

        paint_model(agent_class, prepared_input, model_reference, attempt_index:)
      end

      def check_image_agent!(agent_class)
        refused = image_refusals(agent_class).select { |_, given| given }.keys
        return if refused.empty?

        raise WorkflowError, "#{agent_class} answers with an image, which takes no #{refused.join(", ")}"
      end

      def image_refusals(agent_class)
        {
          "tools" => !Array(agent_class.tools).empty?,
          "an output schema" => !(agent_class.output_schema || agent_class.schema || agent_class.output_contract).nil?,
          "thinking" => !agent_class.thinking.nil?,
          "a streamed step" => !@step_stream.nil?,
          "a batch" => @batch_capturing == true
        }
      end

      # Every attempt of an image agent, a refusal's fallback included.
      def paint_model(agent_class, prepared_input, model_reference, attempt_index:)
        check_image_agent!(agent_class)
        painting_attempt(agent_class, prepared_input, model_reference,
                         { attempt_id: SecureRandom.uuid, attempt_index:, agent_name: agent_class.register_as })
      end

      # The paint's input (PaintInput: its prompt and images) is read once and
      # handed on as it was sent, to the paint and to the attempt's record.
      # The image the provider answered reaches the record through a local
      # that ends with this attempt, kept or not, so nothing holds it longer
      # than 0.16.0 does (its completion holds the kept image's ref alone).
      def painting_attempt(agent_class, prepared_input, model_reference, facts)
        chat = painting_chat(agent_class, prepared_input, model_reference)
        observed = observed_model_reference(chat, fallback: model_reference)
        timer = ProviderCallTiming::Timer.start
        sent = PaintInput.of(chat.messages)
        image = nil
        completion = painted(agent_class, chat, sent, observed, facts[:attempt_id]) { image = _1 }
        completed_provider_attempt(completion, observed, timer.stop, facts, agent_class:, request: sent, image:)
      rescue StandardError => e
        failed_paint(agent_class, e, observed || model_reference, timer&.stop, facts, sent, image)
      end

      # A paint's failure traced as any attempt's: one whose outcome is
      # uncertain is raised as RequestOutcomeUncertain, its cause the
      # transport's error; an image that was drawn and billed but could not be
      # kept has its usage recorded before its error goes on.
      # rubocop:disable Metrics/ParameterLists -- the paint's input and the
      # image (one that came back and could not be kept) are passed as they
      # are, for the attempt's record, so nothing is built for them.
      def failed_paint(agent_class, error, model_reference, timer, facts, sent, image)
        usages = error.is_a?(Unkept) ? [error.usage].compact : []
        record_billed_usages(agent_class, usages, :partial_attempt, model_reference, attempt_id: facts[:attempt_id])
        error = error.reason if error.is_a?(Unkept)
        error = outcome_uncertain(error) if Providers::RequestOutcome.uncertain?(error)
        attempt = failed_provider_attempt(error, model_reference, timer, facts, usages,
                                          agent_class:, request: sent, image:)
        raise error unless provider_failure?(error) || unsupported_content?(error)

        attempt
      end
      # rubocop:enable Metrics/ParameterLists

      def painting_chat(agent_class, prepared_input, model_reference)
        chat = agent_class.chat(**model_reference.chat_options, **bridge_workflow_inputs(agent_class))
        chat = sent_once(chat, agent_class) if chat.respond_to?(:with_context) && chat.respond_to?(:with_model)
        provider = observed_model_reference(chat, fallback: model_reference).provider
        add_prepared_input(chat, prepared_input, provider,
                           ProviderRequest::Shape.new(output_schema: nil, output_limit: nil, prompt_cache: :none))
        chat
      end

      # Yields the provider's image before it is kept, for the attempt's
      # record (painting_attempt).
      def painted(agent_class, chat, sent, model_reference, attempt_id)
        prompt, images = sent
        request = agent_class.image_request
        provider = chat_provider(chat)
        image = held_paint(provider, attempt_id) do
          provider.paint(prompt, model: model_reference.model_id, size: request.fetch(:size),
                                 with: images.empty? ? nil : images, params: request)
        end
        yield image
        painted_completion(agent_class, image)
      rescue ::RubyLLM::BadRequestError => e
        raise unless moderation_blocked?(e)

        refused_completion
      end

      def held_paint(provider, attempt_id, &paint)
        ledger = run_budget_ledger
        return paint.call unless ledger

        Providers::RequestHolds.within(provider, ledger, attempt_id, &paint)
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
end
