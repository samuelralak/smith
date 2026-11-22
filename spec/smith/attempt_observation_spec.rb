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

  around do |example|
    example.run
  ensure
    installed = described_class.observer
    described_class.uninstall(installed) if installed
  end

  def answering(name = "SpecSeamAgent", &)
    agent(name, register: :spec_seam_agent) do
      instructions { |_context| "Answer briefly." }
      class_exec(&) if block_given?
    end
  end

  def run_in_trial(workflow, trial: "trial-1") = Smith::Attribution.with(trial:) { workflow.run! }

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
    it "has each provider attempt read the empty slot and call nothing" do
      answering
      server.reply(json: message("Open at 8."))
      allow(described_class).to receive(:observer).and_call_original
      expect(described_class).not_to receive(:observe)

      expect(run_in_trial(asking("SpecSeamUnusedWorkflow", agent: :spec_seam_agent).new(context: {})).output)
        .to eq("Open at 8.")
      expect(described_class).to have_received(:observer).once
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
      expect(seen.to_h.except(:duration_ms, :messages)).to eq(
        trial: "trial-7", agent: "spec_seam_agent", components: nil,
        attempt_id: workflow.usage_entries.sole.attempt_id, attempt_index: 0, outcome: :completed, failure: nil,
        model: "claude-sonnet-5-5", provider: :anthropic, mode: :sync, memo: false,
        tokens: { input: 30, output: 5, cache_read: nil, cache_write: nil, thinking: nil }, stop_reason: "end_turn",
        sent_count: 2, tool_call_names: [],
        position: { execution_key: "run-7", workflow: "SpecSeamTrialWorkflow", transition: :ask, branch_key: nil,
                    round: nil }
      )
      expect(seen.duration_ms).to be_a(Integer)
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
      answering { define_singleton_method(:smith_prompt_components) { [{ id: "triage", version: "v3" }] } }
      described_class.install(observer)
      server.reply(json: message("Open at 8."))

      run_in_trial(asking("SpecSeamComponentsWorkflow", agent: :spec_seam_agent).new(context: {}))
      expect(observer.seen.sole.components).to eq([{ id: "triage", version: "v3" }])
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
        .to eq("The provider refused the API key.")
      expect(observed(RubyLLM::PaymentRequiredError.new(nil, "card 4242 declined")).failure[:message])
        .to eq("The provider account is out of credit.")
      expect(observed(RubyLLM::ForbiddenError.new(nil, "org org-9 denied")).failure[:message])
        .to eq("The provider refused access to this model.")
      long = observed(RubyLLM::BadRequestError.new(nil, "x" * 5000)).failure[:message]
      expect([long.bytesize <= 1024, long.start_with?("xxx")]).to eq([true, true])
    end

    it "keeps a provider's body out of the record when it refuses the key over the wire" do
      answering
      described_class.install(observer)
      body = { type: "error", error: { type: "authentication_error", message: "invalid key sk-live-secret" } }
      server.reply(json: body, status: "401 Unauthorized")

      run_in_trial(asking("SpecSeamRefusedWorkflow", agent: :spec_seam_agent).new(context: {}))
      expect(observer.seen.sole.failure)
        .to eq(kind: :key_refused, error_class: "RubyLLM::UnauthorizedError",
               message: "The provider refused the API key.")
      expect(observer.seen.sole.messages.map { _1["role"] }).to eq(%w[system user])
    end
  end

  # An image agent's attempt paints (0.16.0's ProviderPaint) and never passes
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

    it "reads the empty slot once and calls nothing when no observer is installed" do
      painting
      server.reply(json: painted)
      allow(described_class).to receive(:observer).and_call_original
      expect(described_class).not_to receive(:observe)

      expect(run_in_trial(asking("SpecSeamPaintUnusedWorkflow", agent: :spec_seam_agent).new(context: {})).state)
        .to eq(:done)
      expect(described_class).to have_received(:observer).once
    end

    it "reads the empty slot once on a failed attempt too, and calls nothing, on its way to the fallback" do
      painting { fallback_models "openai/gpt-image-other" }
      server.reply(json: { "error" => { "message" => "Slow down" } }, status: "429 Too Many Requests")
      server.reply(json: painted)
      allow(described_class).to receive(:observer).and_call_original
      expect(described_class).not_to receive(:observe)

      workflow = asking("SpecSeamPaintFallbackUnusedWorkflow", agent: :spec_seam_agent).new(context: {})
      expect(run_in_trial(workflow).state).to eq(:done)
      expect(provider_calls.map { _1[:outcome] }).to eq(%i[failure success])
      expect(described_class).to have_received(:observer).twice
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
