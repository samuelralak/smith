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
end
