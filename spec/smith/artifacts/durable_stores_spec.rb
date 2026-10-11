# frozen_string_literal: true

require "tmpdir"

RSpec.describe "Smith artifacts: configured, durable stores" do
  before do
    stub_const("Aws::S3::Errors::NoSuchKey", Class.new(StandardError))
    stub_const("Aws::S3::Errors::NotFound", Class.new(StandardError))
  end

  around do |example|
    store = Smith.config.artifact_store
    options = Smith.config.artifact_options
    test_mode = Smith.config.test_mode
    example.run
  ensure
    Smith.configure do |config|
      config.artifact_store = store
      config.artifact_options = options
      config.test_mode = test_mode
    end
  end

  def configure(store, **options)
    Smith.configure do |config|
      config.artifact_store = store
      config.artifact_options = options
    end
  end

  describe "configuration" do
    it "resolves a named store with its options, a store class or object, and caches it" do
      client = FakeS3Client.new
      configure(:s3, bucket: "b", client:)
      expect(Smith.artifacts).to be_a(Smith::Artifacts::S3)
      expect(Smith.artifacts).to equal(Smith.artifacts)

      Dir.mktmpdir do |dir|
        configure(:file, dir:)
        expect(Smith.artifacts).to be_a(Smith::Artifacts::File)
      end
      configure(:active_record, model: "SmithArtifactRecord")
      expect(Smith.artifacts).to be_a(Smith::Artifacts::ActiveRecordStore)
      configure(Smith::Artifacts::Memory, namespace: "tenant")
      expect(Smith.artifacts.namespace).to eq("tenant")
      store = Smith::Artifacts::Memory.new
      configure(store)
      expect(Smith.artifacts).to equal(store)
    end

    it "refuses an unknown or incomplete store, and assumes none outside test mode" do
      configure(:dropbox)
      expect { Smith.artifacts }.to raise_error(ArgumentError, /unknown artifact store :dropbox/)
      configure(Object.new)
      expect { Smith.artifacts }.to raise_error(ArgumentError, /must implement store, fetch/)

      configure(nil)
      Smith.config.test_mode = false
      expect { Smith.artifacts }.to raise_error(Smith::ArtifactStoreMissing, /artifact_store is not configured/)
      Smith.config.test_mode = true
      expect(Smith.artifacts).to be_a(Smith::Artifacts::Memory)
    end

    it "needs no store for a run that keeps no artifacts, and fails a step that stores one without it" do
      configure(nil)
      Smith.config.test_mode = false
      plain = with_stubbed_class("SpecNoArtifacts", Smith::Workflow) do
        initial_state :idle
        transition(:t, from: :idle, to: :done) { compute { |step| step.write_context(:n, 1) } }
      end
      storing = with_stubbed_class("SpecStoresArtifact", Smith::Workflow) do
        initial_state :idle
        state :failed
        transition :t, from: :idle, to: :done do
          compute { |step| step.write_context(:ref, Smith.artifacts.store("x")) }
          on_failure :fail
        end
      end

      expect(plain.new.run!.state).to eq(:done)
      expect(storing.new.run!.last_error).to be_a(Smith::ArtifactStoreMissing)
    end

    it "takes names as Strings, rebuilds on new options, and keeps a configured store by identity" do
      configure("memory")
      expect(Smith.artifacts).to be_a(Smith::Artifacts::Memory)
      first_client = FakeS3Client.new
      configure(:s3, bucket: "one", client: first_client)
      first = Smith.artifacts
      configure(:s3, bucket: "two", client: first_client)
      expect(Smith.artifacts).not_to equal(first)

      Smith.configure { |config| config.artifact_options = nil }
      configure(:memory)
      Smith.config.artifact_options = nil
      expect(Smith.artifacts).to be_a(Smith::Artifacts::Memory)

      equal_store = Struct.new(:name) do
        def store(*, **) = "ref"
        def fetch(_ref) = nil
      end
      configure(equal_store.new("a"))
      kept = Smith.artifacts
      replacement = equal_store.new("a")
      configure(replacement)
      expect(Smith.artifacts).to equal(replacement)
      expect(kept).not_to equal(replacement)
    end

    it "uses a class or module that stores itself, validates a class it builds, and needs store and fetch only" do
      itself = Module.new do
        def self.store(*, **) = "ref"
        def self.fetch(_ref) = "bytes"
      end
      configure(itself)
      expect(Smith.artifacts).to equal(itself)
      itself_class = Class.new do
        def self.store(*, **) = "ref"
        def self.fetch(_ref) = "bytes"
      end
      configure(itself_class)
      expect(Smith.artifacts).to equal(itself_class)

      configure(Class.new { def initialize(**) = nil })
      expect { Smith.artifacts }.to raise_error(ArgumentError, /must implement store, fetch/)
      minimal = Class.new do
        def store(*, **) = "ref"
        def fetch(_ref) = nil
      end
      configure(minimal.new)
      expect { Smith.artifacts }.not_to raise_error
      expect { Smith::Artifacts::ScopedStore.new(namespace: "run").expired }
        .to raise_error(Smith::Error, /does not list expired refs/)
    end

    it "builds one store when threads resolve it together, and keeps a :memory store across test_mode" do
      builds = Queue.new
      slow = Class.new(Smith::Artifacts::Memory) do
        define_method(:initialize) do |**options|
          sleep 0.01
          builds << 1
          super(**options)
        end
      end
      configure(slow)
      stores = Array.new(8) { Thread.new { Smith.artifacts } }.map(&:value)
      expect([builds.size, stores.uniq.size]).to eq([1, 1])

      configure(:memory)
      ref = Smith.artifacts.store("kept")
      Smith.config.test_mode = !Smith.config.test_mode
      expect(Smith.artifacts.fetch(ref)).to eq("kept")
    end

    it "explains that an S3 store needs the SDK or a client" do
      allow(Smith::Artifacts::S3).to receive(:require).with("aws-sdk-s3").and_raise(LoadError)

      expect { Smith::Artifacts::S3.new(bucket: "b") }.to raise_error(Smith::Error, /aws-sdk-s3 gem/)
    end
  end

  describe Smith::Artifacts::S3 do
    let(:client) { FakeS3Client.new }
    let(:store) { described_class.new(bucket: "smith", prefix: "runs/", client:) }

    it "keeps each artifact as one object, with its type and the run that stored it" do
      ref = store.store("%PDF-1.7 bytes".b, content_type: "application/pdf", execution_namespace: "run-a")
      stored = client.objects.fetch(["smith", "runs/#{ref}"])

      expect(ref).to match(/\A\h{8}-\h{4}-\h{4}-\h{4}-\h{12}\z/)
      expect([stored.content_type, stored.metadata])
        .to eq(["application/pdf", { "smith-execution-namespace" => "run-a" }])
      expect(store.fetch(ref)).to eq("%PDF-1.7 bytes")
      expect([store.stored_by?(ref, "run-a"), store.stored_by?(ref, "run-b")]).to eq([true, false])
      expect(store.fetch("00000000-0000-0000-0000-000000000000")).to be_nil
      expect(store.stored_by?("00000000-0000-0000-0000-000000000000", "run-a")).to be(false)
      ["../x", "a/b", "#{ref}.meta", "other:#{ref}"].each { |bad| expect(store.fetch(bad)).to be_nil, bad }

      client.put_object(bucket: "smith", key: "runs/secret.txt", body: "not an artifact", content_type: "x",
                        metadata: {})
      expect(store.fetch("secret.txt")).to be_nil

      store.delete(ref)
      expect(store.fetch(ref)).to be_nil
    end

    it "keeps tenants apart, lists expired refs across pages, and passes other errors on" do
      tenant_a = described_class.new(bucket: "smith", namespace: "tenant-a", client:)
      tenant_b = described_class.new(bucket: "smith", namespace: "tenant-b", client:)
      ref = tenant_a.store("a", execution_namespace: "run-a")
      expect(ref).to start_with("tenant-a:")
      expect(tenant_b.fetch(ref)).to be_nil
      tenant_b.delete(ref)
      expect(tenant_a.fetch(ref)).to eq("a")

      refs = Array.new(5) { |index| store.store("x#{index}", execution_namespace: index.even? ? "run-a" : "run-b") }
      client.objects.each_value { _1.last_modified = Time.now.utc - 3600 }
      expect(store.expired(retention: 60)).to match_array(refs)
      expect(store.expired(retention: 60, execution_namespace: "run-a")).to match_array(refs.values_at(0, 2, 4))
      expect(store.expired(retention: 7200)).to eq([])
      expect(store.expired).to eq([])

      allow(client).to receive(:get_object).and_raise(Timeout::Error)
      expect { store.fetch(refs.first) }.to raise_error(Timeout::Error)
    end
  end

  describe Smith::Artifacts::ActiveRecordStore, :ar do
    let(:store) { described_class.new(model: SmithArtifactRecord) }

    it "keeps each artifact as one row, binary and with the run that stored it" do
      bytes = "\x89PNG\r\n\x1A\nbinary".b
      ref = store.store(bytes, content_type: "image/png", execution_namespace: "run-a")

      expect(store.fetch(ref).b).to eq(bytes)
      expect([store.stored_by?(ref, "run-a"), store.stored_by?(ref, "run-b")]).to eq([true, false])
      expect(described_class.new(model: "SmithArtifactRecord").fetch(ref).b).to eq(bytes)
      ["../x", "#{ref}' OR '1'='1", "other:#{ref}"].each { |bad| expect(store.fetch(bad)).to be_nil, bad }

      tenant = described_class.new(model: SmithArtifactRecord, namespace: "tenant-a")
      kept = tenant.store("t", execution_namespace: "run-a")
      expect(store.fetch(kept)).to be_nil
      expect(tenant.fetch(kept)).to eq("t")

      SmithArtifactRecord.create!(ref: "secret.txt", data: "not an artifact", content_type: "x")
      expect(store.fetch("secret.txt")).to be_nil

      SmithArtifactRecord.where(ref:).update_all(created_at: Time.now.utc - 3600)
      expect(store.expired(retention: 60)).to eq([ref])
      expect(store.expired(retention: 7200)).to eq([])
      expect(store.expired(retention: 60, execution_namespace: "run-b")).to eq([])
      store.delete(ref)
      expect(store.fetch(ref)).to be_nil
    end
  end

  describe "a run's view of its artifacts" do
    it "lets the host read and clean up what a run stored, after the run" do
      configure(:memory)
      klass = with_stubbed_class("SpecHostArtifacts", Smith::Workflow) do
        initial_state :idle
        transition :t, from: :idle, to: :done do
          compute { |step| step.write_context(:ref, Smith.artifacts.store("out")) }
        end
      end
      run = klass.new
      ref = run.run!.context[:ref]
      other = klass.new
      other.run!

      expect([run.artifacts.fetch(ref), other.artifacts.fetch(ref), Smith.artifacts.fetch(ref)])
        .to eq(["out", nil, nil])
      other.artifacts.delete(ref)
      expect(run.artifacts.fetch(ref)).to eq("out")
      shared = other.run!.context[:ref]
      expect(shared.split(":").last).to eq(ref.split(":").last)
      run.artifacts.delete(ref)
      expect([run.artifacts.fetch(ref), other.artifacts.fetch(shared)]).to eq([nil, "out"])
      expect([run.artifacts.fetch(nil), run.artifacts.fetch(42)]).to eq([nil, nil])

      child = Smith::ChildRun.new(ref: 0, key: "k", workflow: klass, input: {}, untrusted_keys: [],
                                  artifact_namespaces: [other.to_state[:execution_namespace]]).build
      expect(child.artifacts.fetch(shared)).to eq("out")
    end

    it "deletes through a custom store that can vouch, only the refs the run stored" do
      deleted = []
      custom = Class.new(Smith::Artifacts::Memory) do
        define_method(:delete) { |ref| deleted << ref }
      end.new
      run_a = Smith::Artifacts::ScopedStore.new(backend: custom, namespace: "run-a")
      run_b = Smith::Artifacts::ScopedStore.new(backend: custom, namespace: "run-b")
      ref = run_a.store("mine")
      run_b.delete(ref.sub("run-a", "run-b"))
      run_a.delete(ref)
      expect(deleted).to eq([ref.delete_prefix("run-a:")])
    end
  end

  describe "a run's documents in a durable store" do
    let(:sent) { [] }

    after { Smith::Agent::Registry.delete(:spec_durable_reader) }

    def register_reader
      Smith::Agent::Registry.delete(:spec_durable_reader)
      recorded = sent
      agent = with_stubbed_class("SpecDurableReader", Smith::Agent) do
        register_as :spec_durable_reader
        model "claude-sonnet-4-5", provider: :anthropic
      end
      agent.define_singleton_method(:chat) do |**|
        chat = Object.new
        chat.define_singleton_method(:add_message) { |message| recorded << message }
        chat.define_singleton_method(:with_schema) { |_schema| self }
        chat.define_singleton_method(:complete) { Struct.new(:content, :input_tokens, :output_tokens).new("ok", 1, 1) }
        chat
      end
    end

    let(:documents_workflow) do
      pdf = ->(ref) { Smith::Message.user([Smith::Content.document(ref, media_type: "application/pdf")]) }
      with_stubbed_class("SpecDurableDocuments", Smith::Workflow) do
        initial_state :idle
        state :failed
        session :isolated
        transition :store, from: :idle, to: :stored do
          compute { |step| step.write_context(:ref, Smith.artifacts.store("%PDF-1.7 lease")) }
        end
        transition :read, from: :stored, to: :done do
          execute :spec_durable_reader, input: ->(ctx) { [pdf.call(ctx[:ref])] }
          on_failure :fail
        end
      end
    end

    def run_reading_documents
      register_reader
      documents_workflow.new.run!
    end

    it "reads them back through S3 and Active Record stores, and a scoped delete removes only the run's own" do
      configure(:s3, bucket: "smith", client: FakeS3Client.new)
      expect(run_reading_documents.state).to eq(:done)
      expect(Base64.decode64(sent.last[:content].value.first.dig(:source, :data))).to eq("%PDF-1.7 lease")

      configure(Smith::Artifacts::ActiveRecordStore, model: SmithArtifactRecord)
      sent.clear
      ActiveRecord::Base.transaction do
        expect(run_reading_documents.state).to eq(:done)
        raise ActiveRecord::Rollback
      end
      expect(sent.last[:content].value.first.dig(:source, :type)).to eq("base64")

      backend = Smith::Artifacts::Memory.new
      parent = Smith::Artifacts::ScopedStore.new(backend:, namespace: "parent")
      child = Smith::Artifacts::ScopedStore.new(backend:, namespace: "child", readable: ["parent"])
      inherited = parent.store("parent's")
      own = child.store("child's")
      child.delete(inherited)
      child.delete(own)
      expect([child.fetch(inherited), child.fetch(own)]).to eq(["parent's", nil])

      deleted = []
      plain = Class.new do
        define_method(:store) { |_data, **| "x" }
        define_method(:fetch) { |_ref| nil }
        define_method(:expired) { |**| [] }
        define_method(:delete) { |ref| deleted << ref }
      end.new
      unvouched = Smith::Artifacts::ScopedStore.new(backend: plain, namespace: "child", readable: ["parent"])
      expect { unvouched.delete("child:def") }.to raise_error(Smith::Error, /needs a store with stored_by\? and delete/)
      expect(deleted).to eq([])
    end
  end
end
