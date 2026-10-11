# frozen_string_literal: true

module Smith
  module Testing
    # A stubbed call bound to its provider object and chat.
    Answering = Data.define(:stub, :provider, :chat) do
      def reply(&) = stub.reply(chat, &)
    end

    # A stubbed agent's call, bound to its provider object and chat, and
    # the transitions a run completes (Workflow).
    module Calls
      private

      def attempt_model(agent_class, ...)
        with_testing_fiber(STUB, Testing.stub_for(agent_class)) { super }
      end

      def complete_chat(chat, ...)
        stub = Fiber[STUB]
        return super unless stub

        with_testing_fiber(ANSWERING, Answering.new(stub:, provider: chat_provider(chat), chat:)) { super }
      end

      def with_testing_fiber(key, value)
        outer = Fiber[key]
        Fiber[key] = value
        yield
      ensure
        Fiber[key] = outer
      end

      def emit_step_completed(transition, output)
        (@testing_transitions ||= []) << transition.name.to_sym
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

    # The same for Smith's OpenAI Responses route.
    module ResponsesRequests
      def complete(provider, *, **, &)
        answering = Testing.answering(provider)
        answering ? answering.reply(&) : super
      end
    end
  end
end
