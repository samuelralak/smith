# frozen_string_literal: true

RSpec.describe "Smith::Artifacts::Memory lifecycle contract" do
  let(:memory_store_class) { require_const("Smith::Artifacts::Memory") }

  it "stores content and fetches it by opaque ref" do
    store = memory_store_class.new
    ref = store.store({ report: "full" }, content_type: "application/json")

    expect(ref).to be_a(String)
    expect(store.fetch(ref)).to eq(report: "full")
  end

  it "reports expired refs when retention is exceeded" do
    store = memory_store_class.new

    ref = store.store("data")
    metadata = store.instance_variable_get(:@metadata)
    metadata[ref][:stored_at] = Time.now.utc - 3600

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

    first_metadata = first_store.instance_variable_get(:@metadata)
    second_metadata = second_store.instance_variable_get(:@metadata)
    first_metadata[first_ref][:stored_at] = Time.now.utc - 3600
    second_metadata[second_ref][:stored_at] = Time.now.utc - 3600

    expect(first_store.expired(retention: 60)).to eq([first_ref])
    expect(second_store.expired(retention: 60)).to eq([second_ref])
  end
end
