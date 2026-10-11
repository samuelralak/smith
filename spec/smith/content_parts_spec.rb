# frozen_string_literal: true

require "base64"
require "json"

RSpec.describe "Smith content parts: Smith::Content and Smith::Message" do
  let(:workflow_class) { require_const("Smith::Workflow") }
  let(:adapter) { Smith::PersistenceAdapters::Memory.new }
  let(:sent) { [] }

  after { %i[spec_parts_reader].each { Smith::Agent::Registry.delete(_1) } }

  # An agent on `model` whose chat records the messages it is given and
  # counts its calls.
  def reader(provider)
    recorded = sent
    model_id = provider == :anthropic ? "claude-sonnet-4-5" : "gpt-5-mini"
    agent = with_stubbed_class("SpecPartsReader", Smith::Agent) do
      register_as :spec_parts_reader
      model(model_id, provider:)
    end
    agent.define_singleton_method(:chat) do |**|
      chat = Object.new
      chat.define_singleton_method(:add_message) { |message| recorded << message }
      chat.define_singleton_method(:with_schema) { |_schema| self }
      chat.define_singleton_method(:complete) do
        recorded << :called
        Struct.new(:content, :input_tokens, :output_tokens).new("read", 1, 1)
      end
      chat
    end
    agent
  end

  # A workflow whose first step stores `bytes` as an artifact of the run and
  # whose second reads it through `input:` built by `message`.
  def reading(name, bytes, &message)
    with_stubbed_class(name, workflow_class) do
      initial_state :idle
      state :failed
      session :isolated
      transition :store, from: :idle, to: :stored do
        compute { |step| step.write_context(:ref, Smith.artifacts.store(bytes)) }
      end
      transition :read, from: :stored, to: :done do
        execute :spec_parts_reader, input: ->(ctx) { [instance_exec(ctx[:ref], &message)] }
        on_failure :fail
      end
    end
  end

  def messages = sent.reject { _1 == :called }

  describe Smith::Content do
    it "builds frozen parts and refuses anything else" do
      expect(described_class.text("hi", cache: true)).to eq("type" => "text", "text" => "hi", "cache" => true)
      expect(described_class.document("r", media_type: "application/pdf"))
        .to eq("type" => "document", "artifact" => "r", "media_type" => "application/pdf")
      expect(described_class.image("r", media_type: "image/webp")).to be_frozen

      [-> { described_class.text("") }, -> { described_class.text(1) }, -> { described_class.text("x", cache: 1) },
       -> { described_class.text("x" * ((1024 * 1024) + 1)) },
       -> { described_class.document("r", media_type: "image/png") },
       -> { described_class.image("r", media_type: "application/pdf") },
       -> { described_class.document("r" * 1025, media_type: "text/plain") },
       -> { described_class.check!("type" => "text", "text" => "x", "cache" => false) },
       -> { described_class.check!("type" => "text", "text" => "x", "extra" => 1) },
       -> { described_class.check!("type" => "audio", "artifact" => "r", "media_type" => "audio/wav") }]
        .each { |build| expect(&build).to raise_error(Smith::WorkflowError) }
    end
  end

  describe Smith::Message do
    it "keeps String content plain, marks parts, and refuses system documents and bad part counts" do
      text = Smith::Content.text("hi")

      expect(described_class.user("plain")).to eq("role" => "user", "content" => "plain")
      expect(described_class.assistant([text])).to eq("role" => "assistant", "content" => [text], "parts" => true)
      expect(described_class.system([text])).to be_frozen
      expect(described_class.parts?(role: "user", content: [], parts: true)).to be(true)

      document = Smith::Content.document("r", media_type: "application/pdf")
      [-> { described_class.system([document]) }, -> { described_class.user([]) },
       -> { described_class.user([text] * 101) }, -> { described_class.user([{ "type" => "text" }]) },
       -> { described_class.check!("role" => "tool", "content" => [text], "parts" => true) },
       -> { described_class.check!("role" => "user", "content" => [text], "parts" => false) }]
        .each { |build| expect(&build).to raise_error(Smith::WorkflowError) }
    end
  end

  describe "an agent step's input" do
    it "gives Anthropic native blocks, cached where asked, with the artifact's bytes" do
      reader(:anthropic)
      klass = reading("SpecPartsAnthropic", "%PDF-1.7 body") do |ref|
        Smith::Message.user([Smith::Content.document(ref, media_type: "application/pdf", cache: true),
                             Smith::Content.text("Who signed?")])
      end

      expect(klass.new.run!.state).to eq(:done)
      content = messages.sole[:content]
      expect(content).to be_a(RubyLLM::Content::Raw)
      expect(content.value).to eq(
        [{ type: "document", source: { type: "base64", media_type: "application/pdf",
                                       data: Base64.strict_encode64("%PDF-1.7 body") },
           cache_control: { type: "ephemeral" } },
         { type: "text", text: "Who signed?" }]
      )
    end

    it "sends a text/plain document as text to Anthropic, and attachments with joined text elsewhere" do
      reader(:anthropic)
      plain = reading("SpecPartsPlain", "line one") do |ref|
        Smith::Message.user([Smith::Content.document(ref, media_type: "text/plain")])
      end
      plain.new.run!
      expect(messages.sole[:content].value)
        .to eq([{ type: "document", source: { type: "text", media_type: "text/plain", data: "line one" } }])

      sent.clear
      Smith::Agent::Registry.delete(:spec_parts_reader)
      reader(:openai)
      other = reading("SpecPartsOpenAI", "\x89PNG bytes".b) do |ref|
        Smith::Message.user([Smith::Content.text("Describe", cache: true), Smith::Content.text("briefly"),
                             Smith::Content.image(ref, media_type: "image/png")])
      end
      other.new.run!
      content = messages.sole[:content]
      expect(content).to be_a(RubyLLM::Content)
      expect(content.text).to eq("Describe\n\nbriefly")
      expect(content.attachments.map { [_1.filename, _1.mime_type, _1.content] })
        .to eq([["image-1.png", "image/png", "\x89PNG bytes".b]])
    end

    it "fails the step before the call for a missing artifact, a ref of another run, or too many cache points" do
      reader(:anthropic)
      missing = reading("SpecPartsMissing", "x") do |_ref|
        Smith::Message.user([Smith::Content.document("nope", media_type: "application/pdf")])
      end
      foreign = reading("SpecPartsForeign", "x") do |ref|
        Smith::Message.user([Smith::Content.document(ref.sub(/\A[^:]+/, SecureRandom.uuid), media_type: "text/plain")])
      end
      cached = reading("SpecPartsCached", "x") do |_ref|
        Smith::Message.user(Array.new(5) { Smith::Content.text("p#{_1}", cache: true) })
      end

      expect(missing.new.run!.last_error.message).to match(/artifact of a document part is missing/)
      expect(foreign.new.run!.last_error.message).to match(/artifact of a document part is missing/)
      expect(cached.new.run!.last_error.message).to match(/5 content parts ask to be cached/)
      expect(sent).not_to include(:called)
    end

    it "refuses an artifact that is not a String or is too large, and a system message in input:" do
      reader(:anthropic)
      stub_const("Smith::Content::MAX_PART_BYTES", 4)
      large = reading("SpecPartsLarge", "12345") do |ref|
        Smith::Message.user([Smith::Content.document(ref, media_type: "application/pdf")])
      end
      system = reading("SpecPartsSystem", "x") { |_ref| Smith::Message.system([Smith::Content.text("rules")]) }

      expect(large.new.run!.last_error.message).to match(/larger than 4 bytes/)
      expect(system.new.run!.last_error.message).to match(/must be a user or assistant message/)
    end
  end

  describe "documents across child runs" do
    around do |example|
      previous = Smith.config.run_launcher
      example.run
    ensure
      Smith.config.run_launcher = previous
    end

    # A child that sends the document under ctx[:ref] to the reader.
    def document_child(name)
      with_stubbed_class(name, workflow_class) do
        initial_state :idle
        state :failed
        session :isolated
        transition :read, from: :idle, to: :done do
          execute :spec_parts_reader,
                  input: lambda { |ctx|
                    [Smith::Message.user([Smith::Content.document(ctx[:ref], media_type: "text/plain")])]
                  }
          on_failure :fail
        end
      end
    end

    def mapping(name, kid)
      with_stubbed_class(name, workflow_class) do
        initial_state :idle
        state :failed
        transition :store, from: :idle, to: :stored do
          compute { |step| step.write_context(:ref, Smith.artifacts.store("the resume")) }
        end
        transition :fan, from: :stored, to: :done do
          map :ids, workflow: kid, max_items: 3, timeout: 60,
                    input: ->(id, ctx) { { ids: [id], ref: ctx[:ref] } }, into: :results, collect: :states,
                    on_item_failure: :collect
          on_failure :fail
        end
      end
    end

    def texts = messages.map { _1[:content].value.first.dig(:source, :data) }

    it "lets a child run, restored or inline, read what its parent stored" do
      reader(:anthropic)
      launched = []
      recorder = Class.new { define_method(:launch) { |children:, **| launched.concat(children) && nil } }
      Smith.config.run_launcher = recorder.new
      parent = mapping("SpecPartsMapParent", document_child("SpecPartsMapChild"))
      parent.new(context: { ids: [1, 2] }).run_persisted!("map-docs", adapter:)

      args = JSON.parse(JSON.generate(launched.first.to_h.except(:workflow)))
      fields = args.transform_keys(&:to_sym).merge(input: args["input"].transform_keys(&:to_sym))
      rebuilt = Smith::ChildRun.new(**fields, workflow: launched.first.workflow)
      child = rebuilt.build
      restored = child.class.from_state(JSON.parse(JSON.generate(child.to_state)))
      expect(restored.run!.state).to eq(:done)
      expect(texts).to eq(["the resume"])
      expect(launched.map(&:artifact_namespaces).uniq.length).to eq(1)

      sent.clear
      Smith.config.run_launcher = Smith::Launchers::Inline.new
      result = parent.new(context: { ids: [1, 2] }).run!
      expect(result.context[:results].map { _1[:status] }).to eq(%w[succeeded succeeded])
      expect(texts).to eq(["the resume", "the resume"])
    end

    it "lets a grandchild read its grandparent's, but no run read another's or its children's" do
      reader(:anthropic)
      Smith.config.run_launcher = Smith::Launchers::Inline.new
      grandchild = document_child("SpecPartsGrandchild")
      middle = with_stubbed_class("SpecPartsMiddle", workflow_class) do
        initial_state :idle
        state :failed
        transition :fan, from: :idle, to: :done do
          map :ids, workflow: grandchild, max_items: 1, timeout: 60,
                    input: ->(id, ctx) { { id:, ref: ctx[:ref] } }, into: :results, collect: :states,
                    on_item_failure: :collect
          on_failure :fail
        end
      end
      top = mapping("SpecPartsTop", middle)

      expect(top.new(context: { ids: [1] }).run!.state).to eq(:done)
      expect(texts).to eq(["the resume"])

      sent.clear
      stranger = reading("SpecPartsStranger", "x") do |ref|
        Smith::Message.user([Smith::Content.document(ref.sub(/\A[^:]+/, "another-run"), media_type: "text/plain")])
      end
      expect(stranger.new.run!.last_error.message).to match(/missing/)

      store = Smith::Artifacts::ScopedStore.new(backend: Smith::Artifacts::Memory.new, namespace: "kid",
                                                readable: ["mom"])
      own = store.store("mine")
      expect(own).to start_with("kid:")
      parent_view = Smith::Artifacts::ScopedStore.new(backend: Smith::Artifacts::Memory.new, namespace: "mom")
      expect(parent_view.fetch(own)).to be_nil
    end

    it "ends a step's artifact scope with the step" do
      seen_scopes = []
      klass = with_stubbed_class("SpecPartsScopeEnds", workflow_class) do
        initial_state :idle
        transition(:t, from: :idle, to: :done) { compute { |_s| seen_scopes << Smith.scoped_artifacts } }
      end
      outer = Smith::Artifacts::ScopedStore.new(backend: Smith::Artifacts::Memory.new, namespace: "outer")
      Smith.scoped_artifacts = outer

      klass.new.run!

      expect(seen_scopes.sole).not_to equal(outer)
      expect(Smith.scoped_artifacts).to equal(outer)
    ensure
      Smith.scoped_artifacts = nil
    end

    it "bounds and checks the namespaces a child inherits" do
      kid = document_child("SpecPartsBoundsChild")
      deep = Array.new(16) { "ns#{_1}" }
      parent = workflow_class.allocate
      parent.instance_variable_set(:@execution_namespace, "self")
      parent.instance_variable_set(:@inherited_artifact_namespaces, deep)
      expect(parent.send(:child_artifact_namespaces)).to eq(["self", *deep.first(15)])

      ok = Smith::ChildRun.new(ref: 0, key: "k", workflow: kid, input: {}, untrusted_keys: [])
      expect(ok.artifact_namespaces).to eq([])
      [["x"] * 17, [1], [""], "ns"].each do |namespaces|
        bad = Smith::ChildRun.new(ref: 0, key: "k", workflow: kid, input: {}, untrusted_keys: [],
                                  artifact_namespaces: namespaces)
        expect { bad.build }.to raise_error(Smith::WorkflowError), namespaces.inspect[0, 30]
      end
      state = Smith::ChildRun.new(ref: 0, key: "k", workflow: kid, input: {}, untrusted_keys: [],
                                  artifact_namespaces: %w[a a b]).build.to_state
      expect(state[:inherited_artifact_namespaces]).to eq(%w[a b])
      expect { kid.from_state(state.merge(inherited_artifact_namespaces: [1])) }.to raise_error(Smith::SerializationError)
    end
  end

  describe "hand-built parts messages" do
    it "are checked in input: and in seed_messages" do
      reader(:anthropic)
      bad = [{ role: :user, content: [{ type: "text" }], parts: true }, { role: :user, content: "x", parts: true }]
      bad.each_with_index do |message, index|
        klass = reading("SpecPartsHandBuilt#{index}", "x") { |_ref| message }
        expect(klass.new.run!.last_error).to be_a(Smith::WorkflowError), message.inspect
      end
      expect(sent).not_to include(:called)

      seeded = with_stubbed_class("SpecPartsBadSeed", workflow_class) do
        initial_state :idle
        image = { type: "image", artifact: "r", media_type: "image/png" }
        seed_messages { [{ role: :system, content: [image], parts: true }] }
        transition(:t, from: :idle, to: :done) { compute { |_s| nil } }
      end
      expect { seeded.new }.to raise_error(Smith::WorkflowError, /text parts only/)
    end
  end

  describe "seed messages and the session" do
    it "keeps parts in seed messages, sends a cached system prefix to Anthropic, and restores them" do
      reader(:anthropic)
      klass = with_stubbed_class("SpecPartsSeeded", workflow_class) do
        initial_state :idle
        seed_messages { [Smith::Message.system([Smith::Content.text("House style.", cache: true)])] }
        transition(:draft, from: :idle, to: :done) { execute :spec_parts_reader }
      end

      workflow = klass.new
      restored = klass.from_state(JSON.parse(JSON.generate(workflow.to_state)))
      restored.run!

      system = messages.find { _1[:role] == :system }
      expect(system[:content].value)
        .to eq([{ type: "text", text: "House style.", cache_control: { type: "ephemeral" } }])
      expect(restored.to_state[:seed_digest]).to eq(workflow.to_state[:seed_digest])
    end

    it "refuses parts outside the seed messages, malformed seed parts, and parts a host admits" do
      klass = with_stubbed_class("SpecPartsRestore", workflow_class) do
        initial_state :idle
        seed_messages { [Smith::Message.user([Smith::Content.text("seed")])] }
        transition(:t, from: :idle, to: :done) { compute { |_s| nil } }
      end
      state = JSON.parse(JSON.generate(klass.new.to_state))
      seed = state["session_messages"].first

      expect(klass.from_state(state).to_state[:session_messages].length).to eq(1)
      later = state.merge("session_messages" => [seed, seed])
      broken = state.merge("session_messages" => [seed.merge("content" => [{ "type" => "text" }])])
      [later, broken].each do |bad|
        expect { klass.from_state(bad) }.to raise_error(Smith::SerializationError)
      end
      expect { klass.new.append_session_messages!(Smith::Message.user([Smith::Content.text("x")])) }
        .to raise_error(Smith::WorkflowError, /cannot carry content parts/)
    end

    it "keeps an agent output shaped like parts as data" do
      reader(:anthropic)
      klass = with_stubbed_class("SpecPartsOutput", workflow_class) do
        initial_state :idle
        transition(:a, from: :idle, to: :b) { compute { |_s| nil } }
        transition(:b, from: :b, to: :done) { execute :spec_parts_reader }
      end
      workflow = klass.new
      shaped = { "role" => "user", "content" => [Smith::Content.document("r", media_type: "application/pdf")],
                 "parts" => true }
      workflow.append_session_messages!({ role: "assistant", content: shaped })

      workflow.run!

      expect(JSON.parse(messages.find { _1[:role].to_s == "assistant" }[:content])).to eq(shaped)
    end
  end
end
