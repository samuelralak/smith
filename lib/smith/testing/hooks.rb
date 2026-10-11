# frozen_string_literal: true

module Smith
  module Testing
    # An agent request Smith::Testing would not send: the agent has no stub
    # and `Smith::Testing.unstubbed` is :refuse.
    class UnstubbedCall < Smith::Error; end

    # An agent's call bound to its provider object and chat, and its stub
    # (nil for an agent with none, when unstubbed requests are refused).
    Answering = Data.define(:stub, :provider, :chat, :agent) do
      def reply(&)
        return stub.reply(chat, &) if stub

        raise UnstubbedCall, "#{agent || "an agent"} has no stub, and Smith::Testing.unstubbed is :refuse"
      end
    end

    # A stubbed agent's call, bound to its provider object and chat, and
    # the transitions a run completes (Workflow).
    module Calls
      private

      def attempt_model(agent_class, ...)
        with_testing_fiber(STUB, Testing.stub_for(agent_class)) { super }
      end

      def complete_chat(chat, model_reference, collected, facts = {})
        stub = Fiber[STUB]
        return super unless stub || Testing.unstubbed == :refuse

        answering = Answering.new(stub:, provider: chat_provider(chat), chat:, agent: facts[:agent_name])
        with_testing_fiber(ANSWERING, answering) { super }
      end

      def with_testing_fiber(key, value)
        outer = Fiber[key]
        Fiber[key] = value
        yield
      ensure
        Fiber[key] = outer
      end

      # Every step a run counts passes here, on every path (a wait's
      # completion and a prepared split-step's included); a failed or
      # timed-out step is not a transition the run went through.
      def record_step_snapshot(step_result)
        if step_result.is_a?(Hash) && step_result[:transition] && !step_result[:error] && !step_result[:timed_out]
          (@testing_transitions ||= []) << step_result[:transition].to_sym
        end
        super
      end
    end

    # A stubbed call's requests, answered where they would go over the wire
    # (RubyLLM::Provider, and Bedrock's own).
    module Requests
      private

      def sync_response(...)
        answering = Testing.answering(self)
        answering ? answering.reply : super
      end

      def stream_response(*, **, &)
        answering = Testing.answering(self)
        answering ? answering.reply(&) : super
      end
    end

    # The same for Smith's OpenAI Responses route, whose request is still
    # rendered (as the chat route's is) before it is answered.
    module ResponsesRequests
      RENDERED = %i[tools temperature model schema thinking tool_prefs].freeze

      def complete(provider, messages, **options, &)
        answering = Testing.answering(provider)
        return super unless answering

        render_response_payload(messages, **options.slice(*RENDERED))
        answering.reply(&)
      end
    end
  end
end
