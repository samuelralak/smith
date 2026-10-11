# frozen_string_literal: true

require "json"
require "smith"
require_relative "testing/stub"
require_relative "testing/checks"
require_relative "testing/hooks"

module Smith
  # Testing a host's workflows without a provider (`require "smith/testing"`).
  #
  #   Smith::Testing.stub_agent(Summarizer, outputs: [Smith::Testing.tool_call(Lookup, id: 7),
  #                                                   "A short summary."],
  #                                         usage: { input_tokens: 40, output_tokens: 8 })
  #   run = Review.new(context: {})
  #   Smith::Testing.run_until_waiting(run)
  #   Smith::Testing.resume_with(run, payload: { approved: true })
  #
  # A stubbed agent's requests are answered where they would go over the
  # wire, so everything above runs as for a provider's reply: the tool loop,
  # budget holds, the response memo, streaming, output checks and repairs,
  # usage entries and budgets. Each request takes the next of its outputs
  # (the last answers every request after it): a String reply, a Hash as
  # JSON text (for an agent with an output schema), or a tool request
  # (`tool_call`, or an Array of them), which runs the agent's own tools
  # before its next request. Replies carry the stub's usage and stop
  # reason; a streamed one reaches its sink in pieces of `stream:`
  # characters. A batch step's request is captured as ever (the batch
  # queue gets it), and its delivery (`batch_payload`) answers it.
  #
  # Only the agent's own requests are answered: a tool's own provider call
  # is not. An agent with no stub goes over the wire, unless `unstubbed =
  # :refuse` fails its call first. Stubs are the process's: `reset!` drops them (smith/testing/
  # minitest and smith/testing/rspec do after each test). The chat is still
  # built, so the agent's provider must be configured (any key).
  # Smith::Testing::Checks are what the Minitest assertions and RSpec
  # matchers check.
  module Testing
    STUB = :smith_testing_stub
    ANSWERING = :smith_testing_answering
    private_constant :STUB, :ANSWERING

    UNSTUBBED = %i[send refuse].freeze

    @stubs = {}
    @stubs_lock = Mutex.new
    @unstubbed = :send

    module_function

    # What an agent request without a stub does: :send (the default) sends
    # it over the wire; :refuse fails its call with UnstubbedCall before
    # anything is sent (a mistyped stub then cannot reach a paid provider).
    def unstubbed = @unstubbed

    def unstubbed=(mode)
      raise ArgumentError, "Smith::Testing.unstubbed is :send or :refuse" unless UNSTUBBED.include?(mode)

      @unstubbed = mode
    end

    # Answers `agent`'s requests (its class, or its registered name) with
    # `outputs`; returns the Stub.
    def stub_agent(agent, outputs:, usage: {}, stop_reason: "end_turn", stream: nil)
      outputs = [outputs] unless outputs.is_a?(Array)
      Stub.check!(outputs, usage, stop_reason, stream)
      stub = Stub.new(outputs:, usage:, stop_reason:, stream:)
      @stubs_lock.synchronize { @stubs[agent.is_a?(Module) ? agent : agent.to_sym] = stub }
    end

    # A tool request, as a stub's output: the model asks for `tool` (its
    # class, or its name as the model sees it) with `arguments`.
    def tool_call(tool, **arguments)
      name = tool.is_a?(Class) ? tool.allocate.name : tool.to_s
      ToolRequest.new(name:, arguments: JSON.parse(JSON.generate(arguments)))
    end

    # The stub for `agent_class`, by class or registered name.
    def stub_for(agent_class)
      @stubs_lock.synchronize { @stubs[agent_class] || @stubs[agent_class.register_as&.to_sym] }
    end

    def reset! = @stubs_lock.synchronize { @stubs.clear }

    # The stubbed call that answers `provider`'s request now, or nil: only
    # the call's own provider object, and never a batch capture or delivery
    # (Providers::BatchExchange answers those).
    def answering(provider)
      answering = Fiber[ANSWERING]
      answering if answering&.provider.equal?(provider) && !Providers::BatchExchange.exchange_for(provider)
    end

    # The transitions the workflow instance completed, in order.
    def transitions(workflow) = (workflow.instance_variable_get(:@testing_transitions) || []).dup

    # Runs the workflow until it waits or ends; returns its wait, or nil. A
    # durable retry's backoff is ended at once unless `retries: false`.
    def run_until_waiting(workflow, retries: true)
      loop do
        workflow.run!
        wait = workflow.awaiting
        return wait unless retries && wait&.kind == :retry

        workflow.expire_wait!(token: wait.token, now: wait.deadline_at + 1)
      end
    end

    # Delivers `payload` to the workflow's wait (its event, unless `event`)
    # and runs it on until it waits or ends; returns what `resume!` did.
    def resume_with(workflow, payload: nil, event: nil)
      wait = waiting!(workflow)
      outcome = workflow.resume!(event: event || wait.event, token: wait.token, payload:)
      run_until_waiting(workflow) unless outcome == :stale
      outcome
    end

    # Ends the workflow's wait as if its deadline had passed and runs it on;
    # returns what `expire_wait!` did.
    def expire(workflow)
      wait = waiting!(workflow)
      outcome = workflow.expire_wait!(token: wait.token, now: wait.deadline_at + 1)
      run_until_waiting(workflow) if outcome == :expired
      outcome
    end

    def waiting!(workflow) = workflow.awaiting || raise(ArgumentError, "the run is not waiting")
    private_class_method :waiting!

    # A batch result as the provider's results file gives it: a succeeded
    # one with `output` (a String, or a Hash as JSON) as its reply, or
    # `type: "errored"`, "canceled" or "expired".
    def batch_result(output = "", type: "succeeded", usage: {}, stop_reason: "end_turn")
      return { "type" => type } unless type == "succeeded"

      text = output.is_a?(String) ? output : JSON.generate(output)
      tokens = { "input_tokens" => usage.fetch(:input_tokens, 10), "output_tokens" => usage.fetch(:output_tokens, 5) }
      { "type" => "succeeded",
        "message" => { "id" => "msg_batch", "type" => "message", "role" => "assistant",
                       "content" => [{ "type" => "text", "text" => text }], "stop_reason" => stop_reason,
                       "usage" => tokens } }
    end

    # The delivery for a waiting batch step: `results` is one result for an
    # agent step, or a fan-out's results by branch key.
    def batch_payload(workflow, results)
      token = waiting!(workflow).token
      results = JSON.parse(JSON.generate(results))
      return { token => results } if results.key?("type")

      results.to_h { |branch_key, result| [Batch.custom_id(token, branch_key), result] }
    end
  end
end

Smith::Workflow.prepend(Smith::Testing::Calls)
RubyLLM::Provider.prepend(Smith::Testing::Requests)
RubyLLM::Providers::Bedrock.prepend(Smith::Testing::Requests)
Smith::Providers::OpenAI::Responses.singleton_class.prepend(Smith::Testing::ResponsesRequests)
