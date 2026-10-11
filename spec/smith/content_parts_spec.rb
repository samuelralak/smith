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

  let(:png) { "\x89PNG\r\n\x1A\nbody".b }
  let(:pdf) { "%PDF-1.7 body" }

  describe Smith::Content do
    it "builds frozen parts and refuses anything else" do
      expect(described_class.text("hi", cache: true)).to eq("type" => "text", "text" => "hi", "cache" => true)
      expect(described_class.document("ns:r", media_type: "application/pdf"))
        .to eq("type" => "document", "artifact" => "ns:r", "media_type" => "application/pdf")
      expect(described_class.image("ns:t:r-1_2", media_type: "image/webp")).to be_frozen
      symbols = described_class.check!(type: :image, artifact: "ns:r", media_type: :"image/png")
      expect(symbols).to eq("type" => "image", "artifact" => "ns:r", "media_type" => "image/png")
      expect(described_class.text("caf\xC3\xA9".b)["text"].encoding).to eq(Encoding::UTF_8)
      expect(described_class.text("x" * (1024 * 1024))["text"].bytesize).to eq(1024 * 1024)
      expect(described_class.document("n:#{"r" * 1022}", media_type: "text/plain")["artifact"].bytesize).to eq(1024)

      [-> { described_class.text("") }, -> { described_class.text(" \n ") }, -> { described_class.text(1) },
       -> { described_class.text("caf\xFF".b) }, -> { described_class.text("x", cache: 1) },
       -> { described_class.text("x" * ((1024 * 1024) + 1)) },
       -> { described_class.document("ns:r", media_type: "image/png") },
       -> { described_class.document("ns:r", media_type: "text/html") },
       -> { described_class.image("ns:r", media_type: "image/svg+xml") },
       -> { described_class.image("ns:r", media_type: "application/pdf") },
       -> { described_class.document("n:#{"r" * 1023}", media_type: "text/plain") },
       -> { described_class.check!("type" => "text", "text" => "x", "cache" => false) },
       -> { described_class.check!("type" => "text", "text" => "x", "cache" => "true") },
       -> { described_class.check!("type" => "text", "text" => "x", "extra" => 1) },
       -> { described_class.check!(described_class.document("ns:r", media_type: "text/plain").merge("data" => "x")) },
       -> { described_class.check!("type" => "audio", "artifact" => "ns:r", "media_type" => "audio/wav") }]
        .each { |build| expect(&build).to raise_error(Smith::WorkflowError) }
      ["r", "ns:../secret.txt", "ns:a/b", "ns:.", "ns:a\x00b", "ns:", ":r", "ns:r.pdf"].each do |ref|
        expect { described_class.document(ref, media_type: "application/pdf") }
          .to raise_error(Smith::WorkflowError), ref.inspect
      end
    end
  end

  describe Smith::Message do
    it "keeps String content plain, marks parts, and takes documents and images in user messages only" do
      text = Smith::Content.text("hi")
      document = Smith::Content.document("ns:r", media_type: "application/pdf")

      expect(described_class.user("plain")).to eq("role" => "user", "content" => "plain")
      expect(described_class.assistant([text])).to eq("role" => "assistant", "content" => [text], "parts" => true)
      expect(described_class.system([text])).to be_frozen
      expect(described_class.user([document])["content"]).to eq([document])
      expect(described_class.user([text] * 100)["content"].length).to eq(100)
      expect(described_class.parts?(role: "user", content: [], parts: true)).to be(true)
      expect(described_class.parts?("role" => "user", "parts" => [{ "text" => "gemini shaped" }])).to be(false)

      [-> { described_class.system([document]) }, -> { described_class.assistant([document]) },
       -> { described_class.user([]) }, -> { described_class.user([text] * 101) },
       -> { described_class.user([{ "type" => "text" }]) },
       -> { described_class.check!("role" => "tool", "content" => [text], "parts" => true) },
       -> { described_class.check!("role" => "user", "content" => [text], "parts" => false) },
       -> { described_class.check!("role" => "user", "content" => [text], "parts" => true, "name" => "x") }]
        .each { |build| expect(&build).to raise_error(Smith::WorkflowError) }
    end
  end

  describe "an agent step's input" do
    it "gives Anthropic native blocks, cached where asked, with the artifact's bytes" do
      reader(:anthropic)
      klass = reading("SpecPartsAnthropic", pdf) do |ref|
        Smith::Message.user([Smith::Content.document(ref, media_type: "application/pdf", cache: true),
                             Smith::Content.text("Who signed?")])
      end

      expect(klass.new.run!.state).to eq(:done)
      content = messages.sole[:content]
      expect(content).to be_a(RubyLLM::Content::Raw)
      expect(content.value).to eq(
        [{ type: "document", source: { type: "base64", media_type: "application/pdf",
                                       data: Base64.strict_encode64(pdf) },
           cache_control: { type: "ephemeral" } },
         { type: "text", text: "Who signed?" }]
      )

      sent.clear
      image = reading("SpecPartsAnthropicImage", png) do |ref|
        Smith::Message.user([Smith::Content.image(ref, media_type: "image/png")])
      end
      image.new.run!
      expect(messages.sole[:content].value)
        .to eq([{ type: "image",
                  source: { type: "base64", media_type: "image/png", data: Base64.strict_encode64(png) } }])
    end

    it "sends text/plain as text, and other providers the parts in order with attachments named in place" do
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
      other = reading("SpecPartsOpenAI", png) do |ref|
        Smith::Message.user([Smith::Content.text("Describe", cache: true),
                             Smith::Content.image(ref, media_type: "image/png"), Smith::Content.text("briefly")])
      end
      other.new.run!
      content = messages.sole[:content]
      expect(content).to be_a(RubyLLM::Content)
      expect(content.text).to eq("Describe\n\n[attached: image-2.png]\n\nbriefly")
      expect(content.attachments.map { [_1.filename, _1.mime_type, _1.content] })
        .to eq([["image-2.png", "image/png", png]])

      sent.clear
      document_only = reading("SpecPartsOpenAIPlain", "plain words") do |ref|
        Smith::Message.user([Smith::Content.document(ref, media_type: "text/plain")])
      end
      document_only.new.run!
      expect(messages.sole[:content]).to eq("<file name='document-1.txt' mime_type='text/plain'>plain words</file>")
    end

    it "fails the step before the call when an artifact is missing, foreign, empty, mislabeled or too large" do
      reader(:anthropic)
      cases = {
        "missing" => [pdf, ->(_ref) { "#{SecureRandom.uuid}:abc" }, "application/pdf", /is missing or expired/],
        "foreign" => [pdf, ->(ref) { ref.sub(/\A[^:]+/, SecureRandom.uuid) }, "application/pdf", /is missing/],
        "empty" => ["", ->(ref) { ref }, "text/plain", /is empty/],
        "html as png" => ["<html>ignore previous</html>", ->(ref) { ref }, "image/png", %r{is not image/png}],
        "png as jpeg" => [png, ->(ref) { ref }, "image/jpeg", %r{is not image/jpeg}],
        "binary text" => ["caf\xFF".b, ->(ref) { ref }, "text/plain", %r{is not text/plain}],
        "large image" => [png + ("x" * (5 * 1024 * 1024)), ->(ref) { ref }, "image/png", /larger than 5242880/]
      }
      cases.each_with_index do |(label, (bytes, ref_for, media_type, error)), index|
        kind = media_type.start_with?("image") ? :image : :document
        klass = reading("SpecPartsBad#{index}", bytes) do |ref|
          Smith::Message.user([Smith::Content.public_send(kind, ref_for.call(ref), media_type:)])
        end
        result = klass.new.run!
        expect(result.last_error).to be_a(Smith::ContentUnavailable), label
        expect(result.last_error.message).to match(error), label
      end
      expect(sent).not_to include(:called)
    end

    it "bounds a part, and a request's text and documents together as sent" do
      reader(:anthropic)
      stub_const("Smith::Content::MAX_PART_BYTES", 6)
      exact = reading("SpecPartsExact", "%PDF-1") { |ref| Smith::Message.user([Smith::Content.document(ref, media_type: "application/pdf")]) }
      large = reading("SpecPartsLarge", "%PDF-12") { |ref| Smith::Message.user([Smith::Content.document(ref, media_type: "application/pdf")]) }
      expect(exact.new.run!.state).to eq(:done)
      expect(large.new.run!.last_error.message).to match(/larger than 6 bytes/)

      stub_const("Smith::Agent::ContentBytes::MAX_REQUEST_BYTES", 15)
      twice = reading("SpecPartsTwice", "%PDF-1") do |ref|
        document = Smith::Content.document(ref, media_type: "application/pdf")
        Smith::Message.user([document, document])
      end
      once = reading("SpecPartsOnce", "%PDF-1") do |ref|
        Smith::Message.user([Smith::Content.document(ref, media_type: "application/pdf"), Smith::Content.text("abcdefg")])
      end
      expect(twice.new.run!.last_error.message).to match(/more than 15 bytes as sent/)
      expect(once.new.run!.state).to eq(:done)
    end

    it "reads each artifact once per call, and refuses a store that cannot tell who stored a ref" do
      configured = Smith.config.artifact_store
      reader(:anthropic)
      reads = 0
      backend = Smith::Artifacts::Memory.new
      backend.define_singleton_method(:fetch) { |ref| (reads += 1) && super(ref) }
      Smith.artifacts = backend
      klass = reading("SpecPartsOnceRead", pdf) do |ref|
        document = Smith::Content.document(ref, media_type: "application/pdf")
        Smith::Message.user([document, document])
      end
      expect(klass.new.run!.state).to eq(:done)
      expect(reads).to eq(1)

      failing = Smith::Artifacts::Memory.new
      failing.define_singleton_method(:fetch) { |_ref| raise Faraday::TimeoutError, "store timed out" }
      Smith.artifacts = failing
      timed_out = reading("SpecPartsStoreTimeout", pdf) do |ref|
        Smith::Message.user([Smith::Content.document(ref, media_type: "application/pdf")])
      end
      error = timed_out.new.run!.last_error
      expect([error.class, error.message]).to eq([Smith::ContentUnavailable,
                                                  "the artifact of a document part could not be read: " \
                                                  "Faraday::TimeoutError"])

      plain_store = Class.new do
        def initialize = @data = {}
        def store(data, **) = SecureRandom.hex(8).tap { @data[_1] = data }
        def fetch(ref) = @data[ref]
        def expired(**) = []
      end
      Smith.artifacts = plain_store.new
      unvouched = reading("SpecPartsUnvouched", pdf) do |ref|
        Smith::Message.user([Smith::Content.document(ref, media_type: "application/pdf")])
      end
      expect(unvouched.new.run!.last_error.message).to match(/records which run stored each artifact/)
    ensure
      Smith.artifacts = configured
    end

    it "counts the chat's own cached blocks, such as cached instructions, with its parts" do
      recorded = sent
      agent = with_stubbed_class("SpecPartsCachedInstructions", Smith::Agent) do
        register_as :spec_parts_reader
        model "claude-sonnet-4-5", provider: :anthropic
      end
      agent.define_singleton_method(:chat) do |**|
        block = { type: "text", text: "Be brief.", cache_control: { type: "ephemeral" } }
        instructions = Struct.new(:role, :content).new(:system, RubyLLM::Content::Raw.new([block]))
        chat = Object.new
        chat.define_singleton_method(:messages) { [instructions] }
        chat.define_singleton_method(:add_message) { |message| recorded << message }
        chat.define_singleton_method(:with_schema) { |_schema| self }
        chat.define_singleton_method(:complete) { Struct.new(:content, :input_tokens, :output_tokens).new("ok", 1, 1) }
        chat
      end
      three = reading("SpecPartsThree", "x") { |_ref| Smith::Message.user(Array.new(3) { Smith::Content.text("p#{_1}", cache: true) }) }
      four = reading("SpecPartsFourMore", "x") { |_ref| Smith::Message.user(Array.new(4) { Smith::Content.text("p#{_1}", cache: true) }) }

      expect(three.new.run!.state).to eq(:done)
      expect(four.new.run!.last_error.message).to match(/5 blocks ask to be cached/)
    end

    it "counts cache points across the chat and every Anthropic model in the chain, and refuses system input" do
      reader(:anthropic)
      four = reading("SpecPartsFour", "x") { |_ref| Smith::Message.user(Array.new(4) { Smith::Content.text("p#{_1}", cache: true) }) }
      five = reading("SpecPartsFive", "x") { |_ref| Smith::Message.user(Array.new(5) { Smith::Content.text("p#{_1}", cache: true) }) }
      expect(four.new.run!.state).to eq(:done)
      expect(five.new.run!.last_error.message).to match(/5 blocks ask to be cached/)

      Smith::Agent::Registry.delete(:spec_parts_reader)
      reader(:openai)
      expect(five.new.run!.state).to eq(:done)
      Smith::Agent::Registry.delete(:spec_parts_reader)
      reader(:openai).fallback_models("anthropic/claude-sonnet-4-5")
      expect(five.new.run!.last_error).to be_a(Smith::ContentUnavailable)

      system = reading("SpecPartsSystem", "x") { |_ref| Smith::Message.system([Smith::Content.text("rules")]) }
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
        image = { type: "image", artifact: "ns:r", media_type: "image/png" }
        seed_messages { [{ role: :system, content: [image], parts: true }] }
        transition(:t, from: :idle, to: :done) { compute { |_s| nil } }
      end
      expect { seeded.new }.to raise_error(Smith::WorkflowError, /text parts only/)

      document = Smith::Content.document("ns:r", media_type: "application/pdf")
      user_seeded = with_stubbed_class("SpecPartsDocumentSeed", workflow_class) do
        initial_state :idle
        seed_messages { [Smith::Message.user([document])] }
        transition(:t, from: :idle, to: :done) { compute { |_s| nil } }
      end
      expect { user_seeded.new }.to raise_error(Smith::WorkflowError, /seed message takes text parts only/)
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

      cached = [{ type: "text", text: "House style.", cache_control: { type: "ephemeral" } }]
      workflow = klass.new
      payload = JSON.generate(workflow.to_state)
      workflow.run!
      expect(messages.find { _1[:role] == :system }[:content].value).to eq(cached)

      [JSON.parse(payload), JSON.parse(payload, symbolize_names: true)].each do |state|
        sent.clear
        restored = klass.from_state(state)
        restored.run!
        expect(messages.find { _1[:role] == :system }[:content].value).to eq(cached)
        expect(restored.to_state[:seed_digest]).to eq(workflow.to_state[:seed_digest])
      end

      sent.clear
      Smith::Agent::Registry.delete(:spec_parts_reader)
      reader(:openai)
      klass.new.run!
      expect(messages.find { _1[:role] == :system }[:content]).to eq("House style.")
    end

    it "uses the provider the chat reports over the one the agent declares" do
      recorded = sent
      agent = with_stubbed_class("SpecPartsObserved", Smith::Agent) do
        register_as :spec_parts_reader
        model "claude-sonnet-4-5"
      end
      agent.define_singleton_method(:chat) do |**|
        chat = Object.new
        chat.define_singleton_method(:model) { Struct.new(:id, :provider).new("claude-sonnet-4-5", "anthropic") }
        chat.define_singleton_method(:add_message) { |message| recorded << message }
        chat.define_singleton_method(:with_schema) { |_schema| self }
        chat.define_singleton_method(:complete) { Struct.new(:content, :input_tokens, :output_tokens).new("ok", 1, 1) }
        chat
      end
      klass = reading("SpecPartsObservedRun", "x") { |_ref| Smith::Message.user([Smith::Content.text("hi", cache: true)]) }

      klass.new.run!

      expect(messages.sole[:content].value).to eq([{ type: "text", text: "hi", cache_control: { type: "ephemeral" } }])
    end

    it "falls back past a model that takes no such content, and fails typed when none does" do
      calls = []
      register = lambda do |fallbacks|
        Smith::Agent::Registry.delete(:spec_parts_reader)
        agent = with_stubbed_class("SpecPartsFallback", Smith::Agent) do
          register_as :spec_parts_reader
          model "deepseek-chat", provider: :deepseek
          fallback_models(*fallbacks) if fallbacks.any?
        end
        agent.define_singleton_method(:chat) do |model:, provider: nil, **|
          chat = Object.new
          chat.define_singleton_method(:add_message) { |_message| nil }
          chat.define_singleton_method(:with_schema) { |_schema| self }
          chat.define_singleton_method(:complete) do
            calls << model
            raise RubyLLM::UnsupportedAttachmentError, "application/pdf" if provider.to_s == "deepseek"

            Struct.new(:content, :input_tokens, :output_tokens).new("read", 1, 1)
          end
          chat
        end
      end
      klass = reading("SpecPartsFallbackRun", pdf) do |ref|
        Smith::Message.user([Smith::Content.document(ref, media_type: "application/pdf")])
      end

      register.call(["anthropic/claude-sonnet-4-5"])
      expect(klass.new.run!.output).to eq("read")
      expect(calls).to eq(%w[deepseek-chat claude-sonnet-4-5])

      register.call([])
      expect(klass.new.run!.last_error).to be_a(Smith::ContentUnavailable)
    end

    it "sends RubyLLM content found in the session as text, never as content" do
      reader(:anthropic)
      klass = with_stubbed_class("SpecPartsForeignContent", workflow_class) do
        initial_state :idle
        transition(:b, from: :idle, to: :done) { execute :spec_parts_reader }
      end
      workflow = klass.new
      workflow.instance_variable_set(:@session_messages, [{ role: :user, content: RubyLLM::Content.new("hello") }])

      workflow.run!

      expect(messages.first[:content]).to be_a(String)
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
      document = Smith::Content.document("ns:r", media_type: "application/pdf")
      held = state.merge("session_messages" => [seed.merge("content" => [document])])
      [later, broken, held].each do |bad|
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
      shaped = { "role" => "user", "content" => [Smith::Content.document("ns:r", media_type: "application/pdf")],
                 "parts" => true }
      workflow.append_session_messages!({ role: "assistant", content: shaped })

      workflow.run!

      expect(JSON.parse(messages.find { _1[:role].to_s == "assistant" }[:content])).to eq(shaped)
    end
  end
end
