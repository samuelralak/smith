# frozen_string_literal: true

module Smith
  class Agent
    # The tool results one provider attempt captures, kept apart so an
    # attempt the call sets aside (for a fallback model or a follow-up,
    # possible only when its tools were replay-safe) takes them with it once
    # the call has its output: the attempt that replaced it ran its tools
    # again and captured anew. Each entry still reaches the step's collector
    # as it comes.
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

      # The accepted output; only now do the attempts set aside on the way
      # take what their tools captured with them, so an invocation that
      # fails after all keeps every capture, as before.
      def accepted_output(agent_class, result, set_aside)
        output = finalize_output(agent_class, result)
        drop_tool_results(set_aside)
        output
      end
    end
  end
end
