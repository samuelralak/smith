# frozen_string_literal: true

require "tmpdir"

RSpec.describe "Smith artifacts: the rules every built-in store keeps" do
  before do
    stub_const("Aws::S3::Errors::NoSuchKey", Class.new(StandardError))
    stub_const("Aws::S3::Errors::NotFound", Class.new(StandardError))
  end

  around do |example|
    isolation = Smith.config.artifact_tenant_isolation
    retention = Smith.config.artifact_retention
    Dir.mktmpdir { |dir| (@dir = dir) && example.run }
  ensure
    Smith.configure do |config|
      config.artifact_tenant_isolation = isolation
      config.artifact_retention = retention
    end
  end

  # Ages an artifact as if it was stored an hour ago.
  def age(store, ref)
    past = Time.now.utc - 3600
    case store
    when Smith::Artifacts::Memory
      claims = store.instance_variable_get(:@metadata).fetch(ref).fetch(:claims)
      claims.each_key { |claim| claims[claim] = past }
    when Smith::Artifacts::File then File.utime(past, past, File.join(@dir, ref))
    when Smith::Artifacts::S3 then @client.objects.each_value { _1.last_modified = past }
    else SmithArtifactRecord.where(ref:).update_all(created_at: past)
    end
  end

  stores = {
    memory: ->(namespace) { Smith::Artifacts::Memory.new(namespace:) },
    file: ->(namespace) { Smith::Artifacts::File.new(dir: @dir, namespace:) },
    s3: ->(namespace) { Smith::Artifacts::S3.new(bucket: "smith", namespace:, client: (@client ||= FakeS3Client.new)) },
    active_record: ->(namespace) { Smith::Artifacts::ActiveRecordStore.new(model: SmithArtifactRecord, namespace:) }
  }

  stores.each do |kind, factory|
    describe "the #{kind} store", :ar do
      define_method(:build) { |namespace = nil| instance_exec(namespace, &factory) }

      it "stores bytes only, takes a plain tenant name, and keeps to the isolation setting" do
        store = build
        expect { store.store({ report: "full" }) }.to raise_error(TypeError, /bytes/)
        ["acme.prod", "acme/prod", "tenant:1", "café", ""].each do |namespace|
          expect { build(namespace) }.to raise_error(ArgumentError, /namespace/), namespace.inspect
        end
        expect(build("acme-prod_1").store("x")).to start_with("acme-prod_1:")

        Smith.config.artifact_tenant_isolation = true
        expect { store.store("x") }.to raise_error(Smith::Error, /requires a namespace/)
        expect(build("tenant").store("x")).to start_with("tenant:")
      end

      it "names a run only for a ref it stored, and never with no run named" do
        store = build
        ref = store.store("%PDF-1.7 bytes".b, content_type: "application/pdf", execution_namespace: "run-a")

        expect(store.fetch(ref).b).to eq("%PDF-1.7 bytes".b)
        expect([store.stored_by?(ref, "run-a"), store.stored_by?(ref, "run-b"), store.stored_by?(ref, nil)])
          .to eq([true, false, false])
        expect(store.stored_by?("other:#{ref}", "run-a")).to be(false)
        hosts = store.store("stored outside a run")
        expect(store.stored_by?(hosts, nil)).to be(false)
        expect(build("tenant").fetch(hosts)).to be_nil
      end

      it "keeps tenants apart in every operation" do
        tenant_a = build("tenant-a")
        tenant_b = build("tenant-b")
        plain = build
        ref = tenant_a.store("a", execution_namespace: "run-a")
        age(tenant_a, ref)

        expect([tenant_b.fetch(ref), plain.fetch(ref)]).to eq([nil, nil])
        expect([tenant_b.stored_by?(ref, "run-a"), plain.stored_by?(ref, "run-a")]).to eq([false, false])
        expect(tenant_b.expired(retention: 60) + plain.expired(retention: 60)).not_to include(ref)
        tenant_b.delete(ref)
        plain.delete(ref)
        expect(tenant_a.fetch(ref)).to eq("a")
      end

      it "lists expired refs by the configured retention and by run, and deletes only what a run stored" do
        store = build
        mine = store.store("mine", execution_namespace: "run-a")
        theirs = store.store("theirs", execution_namespace: "run-b")
        [mine, theirs].each { age(store, _1) }

        expect(store.expired).to eq([])
        Smith.config.artifact_retention = 60
        expect(store.expired).to match_array([mine, theirs])
        expect(store.expired(execution_namespace: "run-a")).to eq([mine])
        expect(store.expired(retention: 7200)).to eq([])

        store.delete(theirs, execution_namespace: "run-a")
        expect(store.fetch(theirs)).to eq("theirs")
        store.delete(theirs, execution_namespace: "run-b")
        store.delete(mine)
        expect([store.fetch(theirs), store.fetch(mine)]).to eq([nil, nil])
      end
    end
  end

  it "keeps a shared Memory artifact for every run that still claims it" do
    store = Smith::Artifacts::Memory.new
    ref = store.store("same bytes", execution_namespace: "run-a")
    expect(store.store("same bytes", execution_namespace: "run-b")).to eq(ref)
    age(store, ref)
    store.store("same bytes", execution_namespace: "run-c")

    expect(store.expired(retention: 60, execution_namespace: "run-a")).to eq([ref])
    expect(store.expired(retention: 60, execution_namespace: "run-c")).to eq([])
    expect(store.expired(retention: 60)).to eq([])
    store.delete(ref, execution_namespace: "run-a")
    expect([store.fetch(ref), store.stored_by?(ref, "run-a"), store.stored_by?(ref, "run-b")])
      .to eq(["same bytes", false, true])
    age(store, ref)
    store.store("same bytes", execution_namespace: "run-b")
    expect(store.expired(retention: 60, execution_namespace: "run-b")).to eq([])
    store.delete(ref, execution_namespace: "run-b")
    store.delete(ref, execution_namespace: "run-c")
    expect(store.fetch(ref)).to be_nil
    expect(store.instance_variable_get(:@metadata)).to be_empty
  end

  it "keeps a File store's deletes inside its directory" do
    File.write(File.join(@dir, "..", "keep.txt"), "outside")
    store = Smith::Artifacts::File.new(dir: @dir)
    store.delete("../keep.txt")
    expect(File.read(File.join(@dir, "..", "keep.txt"))).to eq("outside")
  ensure
    FileUtils.rm_f(File.join(@dir, "..", "keep.txt"))
  end

  describe Smith::Artifacts::S3 do
    let(:client) { FakeS3Client.new }

    it "treats only keys of its ref shape under its prefix as artifacts" do
      store = described_class.new(bucket: "smith", prefix: "artifacts", client:)
      sibling = described_class.new(bucket: "smith", prefix: "artifacts2", client:)
      ref = store.store("x")
      other = sibling.store("y")
      client.put_object(bucket: "smith", key: "artifacts/README", body: "not an artifact", content_type: "x",
                        metadata: {})
      client.put_object(bucket: "smith", key: "artifacts/tenant:#{ref}", body: "tenant's", content_type: "x",
                        metadata: {})
      client.objects.each_value { _1.last_modified = Time.now.utc - 3600 }

      expect(store.expired(retention: 60)).to eq([ref])
      expect([store.fetch("README"), store.fetch("tenant:#{ref}")]).to eq([nil, nil])
      store.delete("README")
      expect(client.objects).to include(%w[smith artifacts/README])
      expect(sibling.expired(retention: 60)).to eq([other])
    end

    it "keys an empty prefix without a leading slash, and takes a client or its options, not both" do
      store = described_class.new(bucket: "smith", prefix: "", client:)
      ref = store.store("x")
      expect(client.objects.keys).to eq([["smith", ref]])
      expect(store.fetch(ref)).to eq("x")
      expect { described_class.new(bucket: "smith", client:, region: "auto") }
        .to raise_error(ArgumentError, /client: or the options/)
    end

    it "raises errors other than a missing object, from every read" do
      store = described_class.new(bucket: "smith", client:)
      ref = store.store("x", execution_namespace: "run-a")
      allow(client).to receive(:head_object).and_raise(Timeout::Error)

      expect { store.stored_by?(ref, "run-a") }.to raise_error(Timeout::Error)
    end
  end

  describe Smith::Artifacts::ActiveRecordStore, :ar do
    it "deletes only its own well-formed refs" do
      store = described_class.new(model: SmithArtifactRecord)
      SmithArtifactRecord.create!(ref: "secret.txt", data: "not an artifact", content_type: "x")
      store.delete("secret.txt")
      expect(SmithArtifactRecord.where(ref: "secret.txt")).to exist
    end
  end
end
