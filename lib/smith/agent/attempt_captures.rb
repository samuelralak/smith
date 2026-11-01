# frozen_string_literal: true

module Smith
  class Agent
    # The tool results one provider attempt captures, kept apart so an
    # attempt the call sets aside (for a fallback model or a follow-up,
    # possible only when its tools were replay-safe) takes them with it:
    # the attempt that replaces it runs its tools again and captures anew.
    # Each entry still reaches the step's collector as it comes.
    module AttemptCaptures
      # A collector that passes each entry on and remembers it.
      class Scope
        def initialize(collector)
          @collector = collector
          @entries = []
          @lock = Mutex.new
        end

        def call(entry)
          accepted = @collector.call(entry)
          @lock.synchronize { @entries << entry }
          accepted
        end

        def entries = @lock.synchronize { @entries.dup.freeze }
      end
      private_constant :Scope

      private

      # The chat's completion (ProviderStreaming#complete_chat), with what
      # its tools capture recorded as `facts[:captures]`, the attempt's,
      # however it ends. A step without a callable collector is left as it
      # is, so strict capture still fails closed there.
      def captured_completion(chat, model_reference, collected, facts)
        collector = Tool.current_tool_result_collector
        return complete_chat(chat, model_reference, collected, facts) unless collector.respond_to?(:call)

        scope = Scope.new(collector)
        Thread.handle_interrupt(Object => :never) do
          Tool.current_tool_result_collector = scope
          begin
            Thread.handle_interrupt(Object => :immediate) { complete_chat(chat, model_reference, collected, facts) }
          ensure
            Tool.current_tool_result_collector = collector
            facts[:captures] = scope.entries
          end
        end
      end

      def discard_captures(attempt) = drop_tool_results(attempt.captures)
    end
  end
end
