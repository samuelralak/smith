# frozen_string_literal: true

require "open3"
require "stringio"

# The recorder seam (slice-1a design, sections 2.2 and 3): one process-wide
# observer slot, read once per provider attempt, observed only inside a
# trial's scope, and never able to change a step.
RSpec.describe Smith::AttemptObservation do
  include_context "with a recording budget ledger"

  let(:observer_class) do
    Class.new do
      attr_reader :seen

      def initialize(&reaction)
        @seen = []
        @reaction = reaction
      end

      def attempt_finished(observation)
        @seen << observation
        @reaction&.call(observation)
      end
    end
  end
  let(:observer) { observer_class.new }
  let(:reference) { Smith::Agent::ModelReference.new(model_id: "claude-sonnet-5-5", provider: :anthropic) }

  around { |example| AttemptObserverSlot.emptied { example.run } }

  def answering(name = "SpecSeamAgent", &)
    agent(name, register: :spec_seam_agent) do
      instructions { |_context| "Answer briefly." }
      class_exec(&) if block_given?
    end
  end

  def run_in_trial(workflow, trial: "trial-1") = Smith::Attribution.with(trial:) { workflow.run! }

  def openai_message(text)
    { "id" => "chatcmpl-1", "object" => "chat.completion", "model" => "gpt-5",
      "choices" => [{ "index" => 0, "finish_reason" => "stop",
                      "message" => { "role" => "assistant", "content" => text } }],
      "usage" => { "prompt_tokens" => 10, "completion_tokens" => 2, "total_tokens" => 12 } }
  end

  # Installing an observer once has RubyLLM's requests read (Sending), so
  # from then on each request reads the slot too, as it does in a process
  # that loaded smith/evals; an app that never installs one has no hook.
  def requests_read
    described_class.install(observer)
    described_class.uninstall(observer)
  end

  describe "the slot" do
    it "is empty unless an observer is installed, holds one observer per process, and refuses a non-observer" do
      other = observer_class.new
      expect(described_class.observer).to be_nil

      described_class.install(observer)
      expect { described_class.install(observer) }.not_to raise_error
      expect { described_class.install(other) }.to raise_error(Smith::Error, /another attempt observer/)
      described_class.uninstall(other)
      expect(described_class.observer).to be(observer)
      described_class.uninstall(observer)
      expect(described_class.observer).to be_nil
      expect { described_class.install(Object.new) }.to raise_error(ArgumentError, /attempt_finished/)
    end
  end

  describe "an app that installs nothing" do
    it "sends RubyLLM's requests as ever: they are read only once an observer is installed" do
      script = <<~RUBY
        require "smith"
        hooks = -> { RubyLLM::Connection.ancestors.take_while { _1 != RubyLLM::Connection }.map(&:name) }
        before = hooks.call
        observer = Object.new.tap { _1.define_singleton_method(:attempt_finished) { |_attempt| nil } }
        2.times { Smith::AttemptObservation.install(observer) }
        p [before, hooks.call]
      RUBY
      stdout, stderr, status = Open3.capture3(RbConfig.ruby, "-I", File.expand_path("../../lib", __dir__),
                                              "-e", script)

      expect([status.success?, stderr]).to eq([true, ""])
      expect(stdout.chomp).to eq('[[], ["Smith::AttemptObservation::Sending"]]')
    end

    it "has each provider attempt, and each request once requests are read, read the empty slot and call nothing" do
      answering
      requests_read
      server.reply(json: message("Open at 8."))
      allow(described_class).to receive(:observer).and_call_original
      expect(described_class).not_to receive(:observe)
      expect(described_class).not_to receive(:sending)

      expect(run_in_trial(asking("SpecSeamUnusedWorkflow", agent: :spec_seam_agent).new(context: {})).output)
        .to eq("Open at 8.")
      expect(described_class).to have_received(:observer).twice
    end
  end

  describe "an installed observer" do
    it "is never called outside a trial's scope" do
      answering
      described_class.install(observer)
      server.reply(json: message("Open at 8."))

      expect(asking("SpecSeamNoTrialWorkflow", agent: :spec_seam_agent).new(context: {}).run!.state).to eq(:done)
      expect(observer.seen).to eq([])
    end

    it "gets one plain, frozen attempt per provider attempt inside a trial, read where it ran" do
      answering
      described_class.install(observer)
      server.reply(json: message("Open at 8.", tokens: [30, 5]))
      workflow = asking("SpecSeamTrialWorkflow", agent: :spec_seam_agent).new(context: {})

      expect(Smith::Attribution.with(trial: "trial-7", execution_key: "run-7") { workflow.run! }.output)
        .to eq("Open at 8.")
      seen = observer.seen.sole
      expect(seen).to be_frozen
      expect(seen.to_h.except(:duration_ms, :messages, :started)).to eq(
        trial: "trial-7", agent: "spec_seam_agent", components: nil,
        attempt_id: workflow.usage_entries.sole.attempt_id, attempt_index: 0, outcome: :completed, failure: nil,
        model: "claude-sonnet-5-5", provider: :anthropic, mode: :sync, memo: false,
        tokens: { input: 30, output: 5, cache_read: nil, cache_write: nil, thinking: nil, image_input: nil,
                  image_output: nil },
        responses: [{ tokens: { input: 30, output: 5, cache_read: nil, cache_write: nil, thinking: nil,
                                image_input: nil, image_output: nil }, mode: :sync }],
        stop_reason: "end_turn", sent_count: 2, tool_call_names: [],
        position: { execution_key: "run-7", workflow: "SpecSeamTrialWorkflow", transition: :ask, branch_key: nil,
                    round: nil },
        settings: { temperature: nil, max_output_tokens: 500, thinking: nil }
      )
      expect([seen.duration_ms, seen.started]).to match([a_kind_of(Integer), a_kind_of(Float)])
      expect(seen.messages).to eq([{ "role" => "system", "text" => "Answer briefly." },
                                   { "role" => "user", "text" => "classify this posting" },
                                   { "role" => "assistant", "text" => "Open at 8." }])
      expect([seen.messages, *seen.messages, seen.tokens, seen.position].all?(&:frozen?)).to be(true)
    end

    # Copying a chat's messages for every observer would cost every trial;
    # the contract (the seam's comment, the CHANGELOG) is that an observer
    # copies before it changes anything.
    it "is frozen only at its top: what its messages hold is the chat's own, which the step goes on to use" do
      schema = Class.new do
        def to_json_schema
          { name: "label", schema: { type: "object", required: ["label"], properties: { label: { type: "string" } } } }
        end
      end
      answering { output_schema schema }
      described_class.install(observer)
      server.reply(json: message('{"label":"bug"}'))

      result = run_in_trial(asking("SpecSeamAliasWorkflow", agent: :spec_seam_agent).new(context: {}))
      seen = observer.seen.sole
      reply = seen.messages.last["json"]
      expect([seen, seen.messages, *seen.messages].all?(&:frozen?)).to be(true)
      expect([reply, reply.frozen?]).to eq([{ "label" => "bug" }, false])
      expect(result.output).to be(reply)
    end

    it "names an agent's prompt components when its class gives them" do
      given = [{ id: "triage", version: "sha256:#{"3" * 64}" }]
      answering { define_singleton_method(:smith_prompt_components) { given } }
      described_class.install(observer)
      server.reply(json: message("Open at 8."))

      run_in_trial(asking("SpecSeamComponentsWorkflow", agent: :spec_seam_agent).new(context: {}))
      expect(observer.seen.sole.components).to eq(given)
    end
  end

  # A step record's offset is computed from its attempt's start, on the
  # monotonic clock its duration is measured on; its settings are those
  # the request was sent with (slice 1a.4).
  describe "when an attempt started, and what it was sent with" do
    def clock = Process.clock_gettime(Process::CLOCK_MONOTONIC)

    it "starts where its timed provider call starts, so the start and the duration end before the attempt does" do
      answering { temperature 0.3 }
      described_class.install(observer)
      server.reply(json: message("Open at 8.", tokens: [30, 5]), after: 0.05)
      workflow = asking("SpecSeamStartWorkflow", agent: :spec_seam_agent).new(context: {})

      before = clock
      run_in_trial(workflow)
      after = clock
      seen = observer.seen.sole
      expect(seen.started).to be_a(Float)
      expect(seen.started).to be_between(before, after)
      expect(seen.started + (seen.duration_ms / 1000.0)).to be <= after + 0.001
      expect(seen.duration_ms).to be >= 50
    end

    it "records the temperature, output limit and thinking the request was sent with, null where unknown" do
      answering do
        model "claude-sonnet-4-5", provider: :anthropic, assume_model_exists: false
        temperature 0.3
        thinking budget: 2048
      end
      described_class.install(observer)
      server.reply(json: message("Open at 8."))

      run_in_trial(asking("SpecSeamSettingsWorkflow", agent: :spec_seam_agent).new(context: {}))
      expect(server.requests.sole.body.slice("temperature", "max_tokens", "thinking"))
        .to eq("temperature" => 0.3, "max_tokens" => 500,
               "thinking" => { "type" => "enabled", "budget_tokens" => 2048 })
      expect(observer.seen.sole.settings).to eq(temperature: 0.3, max_output_tokens: 500, thinking: { budget: 2048 })
      expect(observer.seen.sole.settings).to be_frozen
      kept_on_providers = ObjectSpace.each_object(RubyLLM::Provider).flat_map(&:instance_variables).grep(/smith/i)
      expect(kept_on_providers).to eq([])
    end

    # The hook hands every request over, whatever it holds: one the seam
    # cannot read is read as none, and nothing it does reaches the request.
    it "reads a request it cannot read as none, and never raises into it" do
      described_class.install(observer)
      chat = RubyLLM.chat(model: "claude-sonnet-5-5", provider: :anthropic, assume_model_exists: true)
      attempt = Smith::Agent::ProviderAttempt.failure(error: Smith::AgentError.new("no reply"),
                                                      model_reference: reference, attempt_id: "a-1", attempt_index: 0)
      Smith::Attribution.with(trial: "trial-1") do
        expect { described_class.sending(chat.instance_variable_get(:@provider).connection, "no payload") }
          .not_to raise_error
        expect { described_class.sending(Object.new, { temperature: 0.2 }) }.not_to raise_error
        described_class.observe(attempt, Class.new, chat:)
      end

      expect(observer.seen.sole.settings).to eq(temperature: nil, max_output_tokens: nil, thinking: nil)
    end

    # What the agent declares is not what was sent: RubyLLM's renderers drop
    # what a provider does not take, and params go in beside them.
    it "reads each setting from the request as it went, params included, whatever the agent declares" do
      described_class.install(observer)
      rows = [
        ["gpt-5", :openai, -> { thinking budget: 4096 }, { temperature: nil, max_output_tokens: 500, thinking: nil }],
        ["gpt-5", :openai, -> { thinking effort: :low, budget: 4096 },
         { temperature: nil, max_output_tokens: 500, thinking: { effort: "low" } }],
        ["claude-sonnet-4-5", :anthropic, -> { thinking effort: :low, budget: 2048 },
         { temperature: nil, max_output_tokens: 500, thinking: { budget: 2048 } }],
        ["claude-sonnet-4-5", :anthropic, -> { thinking effort: :none },
         { temperature: nil, max_output_tokens: 500, thinking: nil }],
        ["gpt-4o-search-preview", :openai, -> { temperature 0.2 },
         { temperature: nil, max_output_tokens: 500, thinking: nil }],
        ["gpt-4o", :openai, -> { params max_tokens: 300, temperature: 0.1 },
         { temperature: 0.1, max_output_tokens: 300, thinking: nil }],
        ["gpt-5", :openai, -> { params max_tokens: 500, reasoning_effort: "high" },
         { temperature: nil, max_output_tokens: 500, thinking: { effort: "high" } }]
      ]

      sent = rows.each_with_index.map do |(model, provider, declared, _settings), at|
        answering("SpecSeamSent#{at}Agent") do
          model model, provider:, assume_model_exists: false
          class_exec(&declared)
        end
        server.reply(json: provider == :openai ? openai_message("Open at 8.") : message("Open at 8."))
        run_in_trial(asking("SpecSeamSent#{at}Workflow", agent: :spec_seam_agent).new(context: {}))
        server.requests.last.body.slice("temperature", "max_tokens", "max_completion_tokens", "thinking",
                                        "reasoning_effort")
      end
      expect(observer.seen.map(&:settings)).to eq(rows.map(&:last))
      expect(sent).to eq([{ "max_completion_tokens" => 500 },
                          { "max_completion_tokens" => 500, "reasoning_effort" => "low" },
                          { "max_tokens" => 500, "thinking" => { "type" => "enabled", "budget_tokens" => 2048 } },
                          { "max_tokens" => 500 }, { "max_tokens" => 500 },
                          { "max_tokens" => 300, "temperature" => 0.1 },
                          { "max_completion_tokens" => 500, "reasoning_effort" => "high" }])
    end

    # A key params give as a String beside RubyLLM's Symbol is in the
    # payload twice: json 2 writes both, and a provider reads the last (the
    # params'), which the step records; json 3 refuses to write the request,
    # so it never leaves and the step records none.
    it "reads a params key given as a String beside RubyLLM's Symbol as the one JSON writes last, if it left" do
      answering do
        model "gpt-4o", provider: :openai, assume_model_exists: false
        temperature 0.7
        params "temperature" => 0.3, max_tokens: 300
      end
      described_class.install(observer)
      server.reply(json: openai_message("Open at 8."))

      run_in_trial(asking("SpecSeamStringKeyWorkflow", agent: :spec_seam_agent).new(context: {}))
      seen = observer.seen.sole
      sent = server.requests.map { _1.body["temperature"] }
      left = { temperature: 0.3, max_output_tokens: 300, thinking: nil }
      unwritten = { temperature: nil, max_output_tokens: nil, thinking: nil }
      expect([[[0.3], nil, left], [[], "JSON::GeneratorError", unwritten]])
        .to include([sent, seen.failure&.dig(:error_class), seen.settings])
    end

    # Each provider carries them under its own names; a provider built on
    # one of these (Vertex AI on Gemini, DeepSeek on OpenAI) reads as it. A
    # thinking its model takes none of is left out of the request, and given
    # in params it is sent as given.
    it "reads Gemini's, OpenRouter's, Bedrock's and DeepSeek's requests under their own names" do
      keys = %i[gemini_api_key gemini_api_base openrouter_api_key openrouter_api_base bedrock_api_key
                bedrock_secret_key bedrock_region bedrock_api_base deepseek_api_key deepseek_api_base]
      saved = keys.to_h { [_1, RubyLLM.config.public_send(_1)] }
      RubyLLM.configure do |config|
        config.gemini_api_key = config.openrouter_api_key = config.bedrock_api_key = "test"
        config.deepseek_api_key = config.bedrock_secret_key = "test"
        config.bedrock_region = "us-east-1"
        config.gemini_api_base = config.bedrock_api_base = config.deepseek_api_base = server.url
        config.openrouter_api_base = "#{server.url}/v1"
      end
      described_class.install(observer)
      rows = {
        ["gemini-2.5-flash", :gemini] => [{ generationConfig: { maxOutputTokens: 300 } }, { budget: 1024 }],
        ["openai/gpt-4o", :openrouter] => [{ max_tokens: 200, reasoning: { effort: "low", max_tokens: 512 } },
                                           { effort: :high }],
        ["anthropic.claude-sonnet-4-5", :bedrock] =>
          [{ inferenceConfig: { maxTokens: 400 },
             additionalModelRequestFields: { reasoning_config: { type: "enabled", budget_tokens: 1024 } } },
           { budget: 2048 }],
        ["deepseek-chat", :deepseek] => [{ max_tokens: 250, reasoning_effort: "low" }, { effort: :high }],
        ["amazon.nova-premier-v1:0", :bedrock] =>
          [{ inferenceConfig: { maxTokens: 350 },
             additionalModelRequestFields: { reasoning_config: { type: "enabled", reasoning_effort: "medium" } } },
           { budget: 2048 }]
      }
      replies = [
        { "candidates" => [{ "content" => { "role" => "model", "parts" => [{ "text" => "Open at 8." }] },
                             "finishReason" => "STOP" }],
          "usageMetadata" => { "promptTokenCount" => 10, "candidatesTokenCount" => 2 } },
        openai_message("Open at 8."),
        { "output" => { "message" => { "role" => "assistant", "content" => [{ "text" => "Open at 8." }] } },
          "stopReason" => "end_turn", "usage" => { "inputTokens" => 10, "outputTokens" => 2 } }
      ]
      replies += [openai_message("Open at 8."), replies.last]

      rows.each_with_index do |((model, provider), (params, thinking)), at|
        Smith::Agent::Registry.delete(:spec_seam_agent)
        with_stubbed_class("SpecSeamNamed#{at}Agent", agent_class) do
          register_as :spec_seam_agent
          model model, provider:, assume_model_exists: true
          temperature 0.25
          thinking(**thinking)
          params(**params)
        end
        server.reply(json: replies[at])
        run_in_trial(asking("SpecSeamNamed#{at}Workflow", agent: :spec_seam_agent).new(context: {}))
      end
      expect(observer.seen.map(&:settings)).to eq(
        [{ temperature: 0.25, max_output_tokens: 300, thinking: { budget: 1024 } },
         { temperature: 0.25, max_output_tokens: 200, thinking: { effort: "low", budget: 512 } },
         { temperature: 0.25, max_output_tokens: 400, thinking: { budget: 1024 } },
         { temperature: 0.25, max_output_tokens: 250, thinking: { effort: "low" } },
         { temperature: 0.25, max_output_tokens: 350, thinking: { effort: "medium" } }]
      )
      gemini, openrouter, bedrock, deepseek, embedded = server.requests.map(&:body)
      expect([deepseek.values_at("temperature", "max_tokens", "reasoning_effort"),
              embedded.dig("additionalModelRequestFields", "reasoning_config", "reasoning_effort")])
        .to eq([[0.25, 250, "low"], "medium"])
      expect([gemini.dig("generationConfig", "thinkingConfig", "thinkingBudget"), openrouter["reasoning"],
              openrouter["temperature"], bedrock.dig("additionalModelRequestFields", "reasoning_config"),
              bedrock["inferenceConfig"]])
        .to eq([1024, { "effort" => "low", "max_tokens" => 512 }, 0.25,
                { "type" => "enabled", "budget_tokens" => 1024 }, { "temperature" => 0.25, "maxTokens" => 400 }])
    ensure
      saved&.each { |key, value| RubyLLM.config.public_send(:"#{key}=", value) }
    end

    # A request JSON cannot write (a NaN in its params) fails where it
    # leaves, before anything is sent: it carried nothing to a provider.
    it "has none for a request JSON could not write, which never left" do
      answering { params max_tokens: 300, top_p: Float::NAN }
      described_class.install(observer)

      run_in_trial(asking("SpecSeamUnwrittenWorkflow", agent: :spec_seam_agent).new(context: {}))
      expect([server.requests, observer.seen.sole.failure[:error_class], observer.seen.sole.settings])
        .to eq([[], "JSON::GeneratorError", { temperature: nil, max_output_tokens: nil, thinking: nil }])
    end

    # A batch step's request goes through the host's batch queue, and its
    # result answers the request its call renders again when delivered.
    it "reads a batch step's settings from the request its delivered result answers" do
      Smith.config.batch_queue = queue = batch_queue
      answering do
        model "claude-sonnet-4-5", provider: :anthropic, assume_model_exists: false
        temperature 0.2
      end
      described_class.install(observer)
      workflow = asking("SpecSeamBatchWorkflow", agent: :spec_seam_agent, mode: :batch).new(context: {})

      Smith::Attribution.with(trial: "trial-1") do
        workflow.run!
        workflow.resume!(event: :batch_result, token: workflow.awaiting.token,
                         payload: { queue.items.last[:custom_id] => { "type" => "succeeded",
                                                                      "message" => message("Open at 8.") } })
      end
      expect(queue.items.last[:request]["params"].slice("temperature", "max_tokens"))
        .to eq("temperature" => 0.2, "max_tokens" => 500)
      expect([server.requests, observer.seen.map { [_1.mode, _1.settings] }])
        .to eq([[], [[:batch, { temperature: 0.2, max_output_tokens: 500, thinking: nil }]]])
    end

    it "has none for a request that was never sent, as one its renderer refused before the wire" do
      answering do
        model "claude-sonnet-4-6", provider: :anthropic, assume_model_exists: true
        temperature 0.3
        thinking budget: 2048
      end
      described_class.install(observer)

      run_in_trial(asking("SpecSeamUnsentWorkflow", agent: :spec_seam_agent).new(context: {}))
      expect([server.requests, observer.seen.sole.outcome, observer.seen.sole.settings])
        .to eq([[], :aborted, { temperature: nil, max_output_tokens: nil, thinking: nil }])
    end

    # The budget ledger prices each response alone (a tiered price picks
    # its tier per response), so the seam hands each one over, on the
    # success and the failure path.
    it "hands over each response's tokens and mode, completed or failed part way" do
      stub_const("SpecSeamLookup", Class.new(Smith::Tool) do
        param :query, type: :string, required: true
        define_method(:perform) { |query:| "#{query} opens at 8" }
      end)
      answering { tools SpecSeamLookup }
      described_class.install(observer)
      server.reply(json: message(nil, tokens: [150, 10], content: tool_use("spec_seam_lookup"), stop: "tool_use"))
            .reply(json: message("At 8.", tokens: [160, 5]))
            .reply(json: message(nil, tokens: [150, 10], content: tool_use("spec_seam_lookup"), stop: "tool_use"))
            .reply(json: { type: "error", error: { type: "overloaded_error", message: "busy" } },
                   status: "529 Overloaded")
      workflow = asking("SpecSeamRoundsWorkflow", agent: :spec_seam_agent).new(context: {})
      run_in_trial(workflow)
      failing = asking("SpecSeamRoundsFailWorkflow", agent: :spec_seam_agent).new(context: {})
      run_in_trial(failing)

      counts = observer.seen.map { |seen| seen.responses.map { [*_1[:tokens].values_at(:input, :output), _1[:mode]] } }
      expect(counts).to eq([[[150, 10, :sync], [160, 5, :sync]], [[150, 10, :sync]]])
      expect(observer.seen.map { _1.tokens.values_at(:input, :output) }).to eq([[310, 15], [150, 10]])
      expect([*observer.seen.map(&:responses), *observer.seen.flat_map(&:responses)]).to all(be_frozen)
      by_attempt = [*workflow.usage_entries, *failing.usage_entries].group_by(&:attempt_id)
      expect(observer.seen.map { by_attempt.fetch(_1.attempt_id).map(&:input_tokens) }).to eq([[150, 160], [150]])
    end

    # Claude 5 takes no temperature and thinks adaptively: Smith drops the
    # one and sends the other as an effort (Models::Normalizer).
    it "leaves out what Smith does not send, and gives thinking in the form Smith sends it" do
      answering do
        temperature 0.3
        thinking budget: 2048
      end
      described_class.install(observer)
      server.reply(json: message("Open at 8."))

      run_in_trial(asking("SpecSeamAdaptiveWorkflow", agent: :spec_seam_agent).new(context: {}))
      body = server.requests.sole.body
      expect([body.key?("temperature"), body["output_config"], body["max_tokens"]])
        .to eq([false, { "effort" => "high" }, 500])
      expect(observer.seen.sole.settings).to eq(temperature: nil, max_output_tokens: 500, thinking: { effort: "high" })
    end

    it "has no start or settings for an attempt that failed before its call, and none for a skipped candidate" do
      described_class.install(observer)
      attempt = Smith::Agent::ProviderAttempt.failure(error: Smith::AgentError.new("no model"),
                                                      model_reference: reference, attempt_id: "a-1", attempt_index: 0)
      Smith::Attribution.with(trial: "trial-1") do
        described_class.observe(attempt, answering)
        described_class.skipped(answering, reference, 1, attempt_id: "a-2", provider: :anthropic)
      end

      expect(observer.seen.map { [_1.started, _1.responses, _1.settings] })
        .to eq([[nil, [], { temperature: nil, max_output_tokens: nil, thinking: nil }]] * 2)
    end
  end

  describe "how an attempt ended" do
    def observed(error)
      described_class.install(observer)
      attempt = Smith::Agent::ProviderAttempt.failure(error:, model_reference: reference, attempt_id: "a-1",
                                                      attempt_index: 1)
      Smith::Attribution.with(trial: "trial-1") { described_class.observe(attempt, Class.new) }
      observer.seen.last
    end

    it "reads Smith's own failure families, in order" do
      not_found = RubyLLM::Error.new(Struct.new(:status, :body).new(404, "no such model"), "no such model")
      expected = {
        RubyLLM::UnauthorizedError.new(nil, "bad key sk-1") => %i[failed key_refused],
        RubyLLM::PaymentRequiredError.new(nil, "no credit") => %i[failed out_of_credit],
        RubyLLM::ForbiddenError.new(nil, "not this model") => %i[failed permission],
        not_found => %i[failed model_unavailable],
        RubyLLM::ModelNotFoundError.new("gone") => %i[failed model_unavailable],
        RubyLLM::UnsupportedAttachmentError.new("pdf") => %i[aborted unsupported_content],
        RubyLLM::OverloadedError.new(nil, "busy") => %i[failed transient],
        RubyLLM::RateLimitError.new(nil, "slow down") => %i[failed transient],
        Faraday::ConnectionFailed.new("refused") => %i[failed transport],
        RubyLLM::BadRequestError.new(nil, "bad request") => %i[failed rejected],
        ArgumentError.new("a bug") => %i[aborted aborted]
      }

      expected.each do |error, (outcome, kind)|
        seen = observed(error)
        expect([seen.outcome, seen.failure[:kind], seen.failure[:error_class]])
          .to eq([outcome, kind, error.class.name]), error.class.name
      end
    end

    it "writes Smith's fixed words for a refused key, account or model, and a bounded message otherwise" do
      expect(observed(RubyLLM::UnauthorizedError.new(nil, "key sk-live-1 refused")).failure[:message])
        .to eq("the provider refused the key (HTTP 401)")
      expect(observed(RubyLLM::PaymentRequiredError.new(nil, "card 4242 declined")).failure[:message])
        .to eq("the provider reports no credit")
      expect(observed(RubyLLM::ForbiddenError.new(nil, "org org-9 denied")).failure[:message])
        .to eq("the key has no permission for this model (HTTP 403)")
      long = observed(RubyLLM::BadRequestError.new(nil, "x" * 5000)).failure[:message]
      expect([long.bytesize <= 1024, long.start_with?("xxx")]).to eq([true, true])
    end

    # A billing refusal comes as a 402, or as a 400, 429 or 500 that
    # Smith::BillingRefusals reads as one: its words name no status.
    it "writes the same words for an account out of credit whatever status its refusal came with" do
      answering do
        model "gpt-5", provider: :openai, assume_model_exists: true
      end
      described_class.install(observer)
      quota = "You exceeded your current quota, please check your plan and billing details."
      server.reply(json: { error: { message: quota, type: "insufficient_quota", code: "insufficient_quota" } },
                   status: "429 Too Many Requests")

      run_in_trial(asking("SpecSeamQuotaWorkflow", agent: :spec_seam_agent).new(context: {}))
      expect(observer.seen.sole.failure)
        .to eq(kind: :out_of_credit, error_class: "RubyLLM::PaymentRequiredError",
               message: "the provider reports no credit")
    end

    it "keeps a provider's body out of the record when it refuses the key over the wire" do
      answering
      described_class.install(observer)
      body = { type: "error", error: { type: "authentication_error", message: "invalid key sk-live-secret" } }
      server.reply(json: body, status: "401 Unauthorized")

      run_in_trial(asking("SpecSeamRefusedWorkflow", agent: :spec_seam_agent).new(context: {}))
      expect(observer.seen.sole.failure)
        .to eq(kind: :key_refused, error_class: "RubyLLM::UnauthorizedError",
               message: "the provider refused the key (HTTP 401)")
      expect(observer.seen.sole.messages.map { _1["role"] }).to eq(%w[system user])
    end
  end

  # An image agent's attempt paints (Smith::ImageAttempt) and never passes
  # ProviderCompletion#attempt_model; it is observed where every attempt is
  # recorded, with its one :provider_call trace.
  describe "an image agent's attempt" do
    let(:drawn) { "\x89PNG\r\n\x1A\n".b + "drawn".b }
    let(:painted) do
      { "created" => 1, "data" => [{ "b64_json" => [drawn].pack("m0") }],
        "usage" => { "input_tokens" => 40, "output_tokens" => 823 } }
    end
    let(:traces) { Smith::Trace::Memory.new }

    before do
      image_prices = { input_cost_per_token: 0.000005, output_cost_per_token: 0.00003,
                       image_output_tokens: { "1024x1024" => { "low" => 823 } } }
      Smith.config.pricing = Smith.config.pricing.merge(%w[openai gpt-image-test] => image_prices,
                                                        %w[openai gpt-image-other] => image_prices)
      allow(Smith.config).to receive(:trace_adapter).and_return(traces)
    end

    def painting(name = "SpecSeamPaintAgent", &body)
      Smith::Agent::Registry.delete(:spec_seam_agent)
      klass = with_stubbed_class(name, agent_class) do
        register_as :spec_seam_agent
        model "gpt-image-test", provider: :openai, assume_model_exists: true
        image size: "1024x1024", quality: "low", background: "opaque"
        instructions "Draw it in blue ballpoint."
      end
      klass.class_exec(&body) if body
      klass
    end

    def provider_calls = traces.traces.select { _1[:type] == :provider_call }.map { _1[:data] }

    def pose
      lambda do |context|
        [Smith::Message.user([Smith::Content.text("The pose: standing tall."),
                              Smith::Content.image(context[:guide], media_type: "image/png")])]
      end
    end

    def keep_guide
      guide = "\x89PNG\r\n\x1A\n".b + "guide".b
      ->(step) { step.write_context(:guide, Smith.artifacts.store(guide, content_type: "image/png")) }
    end

    # Draws from a guide image the run keeps, so the request is an edit with
    # an image in it.
    def guided(name)
      input = pose
      keep = keep_guide
      with_stubbed_class(name, workflow_class) do
        initial_state :idle
        state :stored
        state :failed
        transition :store, from: :idle, to: :stored do
          compute(&keep)
        end
        transition :draw, from: :stored, to: :done do
          execute :spec_seam_agent, output_to: :drawn, input: input
          on_failure :fail
        end
      end
    end

    it "reads the empty slot once, and once for its request, and calls nothing when no observer is installed" do
      painting
      requests_read
      server.reply(json: painted)
      allow(described_class).to receive(:observer).and_call_original
      expect(described_class).not_to receive(:observe)

      expect(run_in_trial(asking("SpecSeamPaintUnusedWorkflow", agent: :spec_seam_agent).new(context: {})).state)
        .to eq(:done)
      expect(described_class).to have_received(:observer).twice
    end

    it "reads the empty slot once on a failed attempt too, and calls nothing, on its way to the fallback" do
      painting { fallback_models "openai/gpt-image-other" }
      requests_read
      server.reply(json: { "error" => { "message" => "Slow down" } }, status: "429 Too Many Requests")
      server.reply(json: painted)
      allow(described_class).to receive(:observer).and_call_original
      expect(described_class).not_to receive(:observe)

      workflow = asking("SpecSeamPaintFallbackUnusedWorkflow", agent: :spec_seam_agent).new(context: {})
      expect(run_in_trial(workflow).state).to eq(:done)
      expect(provider_calls.map { _1[:outcome] }).to eq(%i[failure success])
      expect(described_class).to have_received(:observer).exactly(4).times
    end

    # The paint's image reaches the record through a local of its attempt,
    # so a host's after_completion (an upload, say) runs with no image of
    # Smith's alive, as on 0.16.0, observed or not.
    it "keeps no RubyLLM::Image alive past its attempt, with or without an observer" do
      alive = []
      encoded = painted.dig("data", 0, "b64_json")
      painting do
        define_method(:after_completion) do |result, _context|
          GC.start
          alive << ObjectSpace.each_object(RubyLLM::Image).count { _1.data == encoded }
          result
        end
      end
      klass = asking("SpecSeamPaintKeptWorkflow", agent: :spec_seam_agent)
      server.reply(json: painted)
      expect(klass.new(context: {}).run!.state).to eq(:done)
      described_class.install(observer)
      server.reply(json: painted)
      expect(run_in_trial(klass.new(context: {})).state).to eq(:done)

      expect([alive, observer.seen.length]).to eq([[0, 0], 1])
    end

    it "is observed once inside a trial, as its one :provider_call trace" do
      painting
      described_class.install(observer)
      server.reply(json: painted)

      result = run_in_trial(asking("SpecSeamPaintWorkflow", agent: :spec_seam_agent).new(context: {}))
      expect(result.state).to eq(:done)
      expect(observer.seen.map(&:attempt_id)).to eq(provider_calls.map { _1[:attempt_id] })
      expect(observer.seen.map(&:outcome)).to eq(%i[completed])
    end

    # Image tokens are priced at their own rates, so the seam hands them on.
    it "hands over an image's image token counts, in its tokens and its one response" do
      painting
      described_class.install(observer)
      server.reply(json: painted.merge("usage" => { "input_tokens" => 40, "output_tokens" => 823,
                                                    "input_tokens_details" => { "image_tokens" => 30 } }))

      run_in_trial(asking("SpecSeamPaintTokensWorkflow", agent: :spec_seam_agent).new(context: {}))
      seen = observer.seen.sole
      expect(seen.tokens.slice(:input, :output, :image_input, :image_output))
        .to eq(input: 40, output: 823, image_input: 30, image_output: 823)
      expect(seen.responses).to eq([{ tokens: seen.tokens, mode: :sync }])
      expect(seen.settings).to eq(temperature: nil, max_output_tokens: nil, thinking: nil)
    end

    it "holds the request's text and settings and a reference to what came back, never the image's bytes" do
      painting
      described_class.install(observer)
      server.reply(json: painted)

      result = run_in_trial(guided("SpecSeamGuidedWorkflow").new(context: {}))
      seen = observer.seen.sole
      prompt = server.requests.sole.body[/name="prompt"\r\n\r\n(.*?)\r\n--/m, 1]
      expect([result.state, server.requests.sole.body]).to match([:done, include("guide")])
      expect(seen.messages).to eq(
        [{ "role" => "user", "text" => prompt,
           "settings" => { "size" => "1024x1024", "quality" => "low", "background" => "opaque",
                           "output_format" => "png" } },
         { "role" => "assistant",
           "image" => { "mime_type" => "image/png", "bytes" => drawn.bytesize,
                        "sha256" => Digest::SHA256.hexdigest(drawn) } }]
      )
      expect(prompt).to start_with("Draw it in blue ballpoint.").and include("The pose: standing tall.")
      expect(seen.to_h.slice(:sent_count, :tool_call_names, :mode, :stop_reason, :outcome))
        .to eq(sent_count: 1, tool_call_names: [], mode: :sync, stop_reason: nil, outcome: :completed)
      expect([seen.messages, *seen.messages, seen.messages.first["settings"], seen.messages.last["image"]])
        .to all(be_frozen)
      kept = Marshal.dump(seen.to_h)
      expect([kept.include?("drawn"), kept.include?("guide"), kept.include?([drawn].pack("m0"))])
        .to eq([false, false, false])
    end

    # The settings and media type are what the agent declared with `image`,
    # whatever methods of those names it defines.
    it "records the declared settings and media type, never what the agent's own readers answer" do
      painting do
        image size: "1024x1024", quality: "low", output_format: "webp"
        define_singleton_method(:image_request) { { size: "mine" } }
        define_singleton_method(:image_media_type) { "text/plain" }
      end
      described_class.install(observer)
      server.reply(json: painted)

      run_in_trial(asking("SpecSeamDeclaredWorkflow", agent: :spec_seam_agent).new(context: {}))
      user, assistant = observer.seen.sole.messages
      expect(user["settings"]).to eq("size" => "1024x1024", "quality" => "low", "output_format" => "webp")
      expect(assistant["image"]["mime_type"]).to eq("image/webp")
    end

    it "observes a failure that falls back, its record the request alone, then the fallback's image" do
      painting { fallback_models "openai/gpt-image-other" }
      described_class.install(observer)
      server.reply(json: { "error" => { "message" => "Slow down" } }, status: "429 Too Many Requests")
      server.reply(json: painted)

      result = run_in_trial(guided("SpecSeamFallbackWorkflow").new(context: {}))
      failed, completed = observer.seen
      expect(result.state).to eq(:done)
      expect(observer.seen.map(&:attempt_id)).to eq(provider_calls.map { _1[:attempt_id] })
      expect([failed.outcome, failed.failure[:kind], failed.model]).to eq([:failed, :transient, "gpt-image-test"])
      expect([completed.outcome, completed.model]).to eq([:completed, "gpt-image-other"])
      expect(failed.messages.map { _1["role"] }).to eq(%w[user])
      expect(completed.messages.last["image"]["sha256"]).to eq(Digest::SHA256.hexdigest(drawn))
    end

    it "describes an image that came back but could not be kept, as a kept one is, on its failed attempt" do
      painting
      described_class.install(observer)
      kept_only = drawn
      store = Class.new(Smith::Artifacts::Memory) do
        define_method(:store) do |data, **options|
          raise IOError, "the store is down" if data == kept_only

          super(data, **options)
        end
      end
      allow(Smith.config).to receive(:artifact_store).and_return(store.new)
      server.reply(json: painted)

      result = run_in_trial(guided("SpecSeamUnkeptWorkflow").new(context: {}))
      seen = observer.seen.sole
      expect([result.state, seen.outcome, seen.failure[:error_class]]).to eq([:failed, :aborted, "IOError"])
      expect(seen.messages.map { _1["role"] }).to eq(%w[user assistant])
      expect(seen.messages.last["image"])
        .to eq("mime_type" => "image/png", "bytes" => drawn.bytesize, "sha256" => Digest::SHA256.hexdigest(drawn))
    end

    it "takes a moderation block as an answer with no image: its record is the request alone" do
      painting
      described_class.install(observer)
      blocked = { "error" => { "code" => "moderation_blocked", "message" => "Rejected by the safety system." } }
      server.reply(json: blocked, status: "400 Bad Request")

      run_in_trial(asking("SpecSeamBlockedWorkflow", agent: :spec_seam_agent).new(context: {}))
      seen = observer.seen.sole
      expect(seen.to_h.slice(:outcome, :stop_reason)).to eq(outcome: :completed, stop_reason: "moderation_blocked")
      expect(seen.messages.map { _1["role"] }).to eq(%w[user])
    end
  end

  describe "an observer that raises" do
    it "changes no step's result, on the success and the failure path, and Smith's logger gets its class only" do
      answering { fallback_models model: "claude-haiku-5-5", provider: :anthropic }
      overloaded = { type: "error", error: { type: "overloaded_error", message: "Overloaded" } }
      reply = -> { server.reply(json: overloaded, status: "529 Overloaded").reply(json: message("Open at 8.")) }
      klass = asking("SpecSeamRaisingWorkflow", agent: :spec_seam_agent)
      reply.call
      plain = run_in_trial(klass.new(context: {}))

      described_class.install(observer_class.new { raise "secret detail of the observer" })
      reply.call
      raised = run_in_trial(klass.new(context: {}))

      kept = ->(run) { run.usage_entries.map { _1.to_h.except(:usage_id, :attempt_id, :recorded_at) } }
      expect([raised.state, raised.output, kept.call(raised)]).to eq([plain.state, plain.output, kept.call(plain)])
      expect(described_class.observer.seen.map(&:outcome)).to eq(%i[failed completed])
      expect(log.string.lines.grep(/observer error/).map { _1.strip.split(" -- : ").last })
        .to eq(["Smith attempt observer error: RuntimeError"] * 2)
      expect(log.string).not_to include("secret detail")
    end

    it "never lets a logger that raises reach the step either" do
      answering
      described_class.install(observer_class.new { raise "observer" })
      Smith.config.logger = Class.new { def error(*) = raise("logger") }.new
      server.reply(json: message("Open at 8."))

      expect(run_in_trial(asking("SpecSeamLoggerWorkflow", agent: :spec_seam_agent).new(context: {})).output)
        .to eq("Open at 8.")
    end
  end

  describe "its names" do
    # A bare constant in a host's class body is looked up through the class's
    # ancestors before Object, so a seam constant under Smith::Agent would
    # shadow a host's own `Transcript` in every agent subclass.
    it "never shadow a host's own top-level constants inside its agent, workflow or tool classes" do
      script = <<~RUBY
        require "smith"
        class Transcript; def self.create!(**) = :host_transcript; end
        class InterviewAgent < Smith::Agent
          register_as :interview
          def self.keep = Transcript.create!(text: "x")
        end
        p InterviewAgent.keep
        class AttemptObservation; end
        class InterviewWorkflow < Smith::Workflow; def self.seam = AttemptObservation; end
        class InterviewTool < Smith::Tool; def self.seam = [Transcript, AttemptObservation]; end
        p [InterviewWorkflow.seam, InterviewTool.seam]
      RUBY
      stdout, stderr, status = Open3.capture3(RbConfig.ruby, "-I", File.expand_path("../../lib", __dir__),
                                              "-e", script)

      expect([status.success?, stderr]).to eq([true, ""])
      expect(stdout.lines(chomp: true))
        .to eq([":host_transcript", "[AttemptObservation, [Transcript, AttemptObservation]]"])
    end
  end

  describe "the trial member of Smith::Attribution::Context" do
    let(:context_class) { Smith::Attribution::Context }

    it "is last and optional, so a context built by position means what it did" do
      fields = { execution_key: "run-1", transition: :ask, from: :idle, to: :done, branch_key: :left, round: 2,
                 workflow: "W" }

      positional = context_class.new("run-1", :ask, :idle, :done, :left, 2, "W")
      expect(positional).to eq(context_class.new(**fields))
      expect(positional.to_h).to eq(fields.merge(trial: nil))
      expect(positional.to_fields).to eq(fields)
      expect(context_class.members.last).to eq(:trial)
      expect { context_class.new("run-1", :ask, :idle, :done, :left, 2) }
        .to raise_error(ArgumentError, "missing keyword: :workflow")
      expect(Smith::Attribution::EMPTY.to_fields).to eq({})
    end

    it "is carried by every overlay and never reaches a payload" do
      Smith::Attribution.with(trial: "trial-1") do
        Smith::Attribution.with(round: 1, branch_key: :left) do
          expect(Smith::Attribution.current.trial).to eq("trial-1")
          expect(Smith::Attribution.current_fields).to eq(round: 1, branch_key: :left)
        end
        expect(Smith::Attribution.current.override(transition: :ask).trial).to eq("trial-1")
      end
      expect(Smith::Attribution.current).to be_nil
    end
  end
end

RSpec.describe Smith::AttemptObservation::Transcript do
  it "turns a chat's messages into plain frozen entries, referencing their strings" do
    text = +"Answer briefly."
    calls = { "toolu_1" => RubyLLM::ToolCall.new(id: "toolu_1", name: "lookup", arguments: { "query" => "x" }) }
    raw = RubyLLM::Content::Raw.new([{ type: "text", text: "First." }, { type: "image", source: {} },
                                     { type: "text", text: "Second.", cache_control: { type: "ephemeral" } }])
    upload = RubyLLM::Attachment.new(StringIO.new("%PDF-1.7 bytes"), filename: "terms.pdf")
    messages = [
      RubyLLM::Message.new(role: :system, content: text),
      RubyLLM::Message.new(role: :user, content: RubyLLM::Content.new("Read this.", [upload])),
      RubyLLM::Message.new(role: :user, content: raw),
      RubyLLM::Message.new(role: :assistant, content: "", tool_calls: calls,
                           thinking: RubyLLM::Thinking.new(text: "Look it up.", signature: "sig")),
      RubyLLM::Message.new(role: :tool, content: '{"found":"x"}', tool_call_id: "toolu_1"),
      # RubyLLM's constructor reads a Hash as attachments; a parsed reply is set after.
      RubyLLM::Message.new(role: :assistant, content: "").tap { _1.content = { "label" => "bug" } }
    ]

    transcript = described_class.messages(messages)
    expect(transcript).to eq([
                               { "role" => "system", "text" => "Answer briefly." },
                               { "role" => "user", "text" => "Read this.",
                                 "attachments" => [{ "filename" => "terms.pdf", "mime_type" => "application/pdf",
                                                     "bytes" => 14 }] },
                               { "role" => "user", "text" => "First.\n\nSecond.", "cached" => true },
                               { "role" => "assistant", "text" => "",
                                 "tool_calls" => [{ "id" => "toolu_1", "name" => "lookup",
                                                    "arguments" => { "query" => "x" } }],
                                 "thinking" => "Look it up." },
                               { "role" => "tool", "text" => '{"found":"x"}', "tool_call_id" => "toolu_1" },
                               { "role" => "assistant", "json" => { "label" => "bug" } }
                             ])
    expect(transcript.first["text"]).to be(text)
    expect([transcript, *transcript].all?(&:frozen?)).to be(true)
  end

  it "offers messages and painting alone; its readers are its own" do
    expect(described_class.singleton_class.public_instance_methods(false)).to contain_exactly(:messages, :painting)
  end

  it "never reads an attachment's content to describe it" do
    remote = RubyLLM::Attachment.new("https://example.test/terms.pdf")
    expect(remote).not_to receive(:content)

    entry = described_class.messages([RubyLLM::Message.new(role: :user, content: RubyLLM::Content.new("Hi", [remote]))])
    expect(entry.sole["attachments"]).to eq([{ "filename" => "terms.pdf", "mime_type" => "application/pdf",
                                               "bytes" => nil }])
  end
end
