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
end
