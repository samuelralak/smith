# frozen_string_literal: true

RSpec.describe "Smith::Artifacts::Memory lifecycle contract" do
  let(:memory_store_class) { require_const("Smith::Artifacts::Memory") }

  # Ages every claim on a ref, as if each run stored it `seconds` ago.
  def age(store, ref, seconds)
    claims = store.instance_variable_get(:@metadata).fetch(ref).fetch(:claims)
    claims.each_key { |claim| claims[claim] = Time.now.utc - seconds }
  end

  it "stores bytes and fetches them by opaque ref, and refuses anything else" do
    store = memory_store_class.new
    ref = store.store(JSON.generate(report: "full"), content_type: "application/json")

    expect(ref).to be_a(String)
    expect(JSON.parse(store.fetch(ref))).to eq("report" => "full")
    expect { store.store({ report: "full" }) }.to raise_error(TypeError, /bytes/)
  end

  it "reports expired refs when retention is exceeded" do
    store = memory_store_class.new

    ref = store.store("data")
    age(store, ref, 3600)

    expect(store.expired(retention: 60)).to include(ref)
  end

  it "does not report fresh refs as expired" do
    store = memory_store_class.new

    ref = store.store("fresh")

    expect(store.expired(retention: 3600)).not_to include(ref)
  end

  it "returns distinct opaque refs for distinct stored payloads" do
    store = memory_store_class.new

    first_ref = store.store("one")
    second_ref = store.store("two")

    expect(first_ref).to be_a(String)
    expect(second_ref).to be_a(String)
    expect(first_ref).not_to eq(second_ref)
    expect(first_ref).not_to eq("one")
    expect(second_ref).not_to eq("two")
  end

  it "isolates data between separate store instances" do
    first_store = memory_store_class.new
    second_store = memory_store_class.new

    ref = first_store.store("first")

    expect(second_store.fetch(ref)).to be_nil
  end

  it "prefixes refs with the configured namespace when present" do
    store = memory_store_class.new(namespace: "execution-123")

    ref = store.store("report")

    expect(ref).to start_with("execution-123:")
  end

  it "generates distinct refs for identical payloads stored in different namespaces" do
    first_store = memory_store_class.new(namespace: "execution-a")
    second_store = memory_store_class.new(namespace: "execution-b")

    first_ref = first_store.store("same-payload")
    second_ref = second_store.store("same-payload")

    expect(first_ref).not_to eq(second_ref)
    expect(first_ref).to start_with("execution-a:")
    expect(second_ref).to start_with("execution-b:")
  end

  it "reuses the same ref for identical payloads in the same namespace" do
    store = memory_store_class.new(namespace: "execution-a")

    first_ref = store.store("same-payload")
    second_ref = store.store("same-payload")

    expect(first_ref).to eq(second_ref)
  end

  it "fetches a namespaced ref within the same namespace" do
    store = memory_store_class.new(namespace: "execution-123")

    ref = store.store("report")

    expect(store.fetch(ref)).to eq("report")
  end

  it "does not fetch a ref owned by a different namespace" do
    first_store = memory_store_class.new(namespace: "execution-a")
    second_store = memory_store_class.new(namespace: "execution-b")

    ref = first_store.store("shared")

    expect(second_store.fetch(ref)).to be_nil
  end

  it "does not fetch a namespaced ref from a non-namespaced store" do
    namespaced_store = memory_store_class.new(namespace: "execution-a")
    default_store = memory_store_class.new

    ref = namespaced_store.store("payload")

    expect(default_store.fetch(ref)).to be_nil
  end

  it "reports expired refs only within the store namespace" do
    first_store = memory_store_class.new(namespace: "execution-a")
    second_store = memory_store_class.new(namespace: "execution-b")

    first_ref = first_store.store("first")
    second_ref = second_store.store("second")

    age(first_store, first_ref, 3600)
    age(second_store, second_ref, 3600)

    expect(first_store.expired(retention: 60)).to eq([first_ref])
    expect(second_store.expired(retention: 60)).to eq([second_ref])
  end

  it "uses the configured artifact retention when no retention is passed" do
    store = memory_store_class.new(namespace: "execution-a")
    original_retention = Smith.config.artifact_retention

    Smith.configure { |config| config.artifact_retention = 60 }

    ref = store.store("data")
    age(store, ref, 3600)

    expect(store.expired).to eq([ref])
  ensure
    Smith.configure { |config| config.artifact_retention = original_retention }
  end

  it "requires a namespace when artifact tenant isolation is enabled" do
    store = memory_store_class.new
    original_value = Smith.config.artifact_tenant_isolation

    Smith.configure { |config| config.artifact_tenant_isolation = true }

    expect { store.store("payload") }.to raise_error(require_const("Smith::Error"), /artifact_tenant_isolation requires a namespace/)
  ensure
    Smith.configure { |config| config.artifact_tenant_isolation = original_value }
  end
end
