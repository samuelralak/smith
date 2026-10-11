# frozen_string_literal: true

require "tmpdir"

RSpec.describe "Smith artifacts: refs stay with the runs that stored them" do
  around do |example|
    Dir.mktmpdir { |dir| (@dir = dir) && example.run }
  end

  def scoped(backend, namespace, readable: []) = Smith::Artifacts::ScopedStore.new(backend:, namespace:, readable:)

  [-> { Smith::Artifacts::Memory.new }, -> { Smith::Artifacts::File.new(dir: @dir) }].each_with_index do |build, index|
    it "reads a ref only in a run that stored it or may read its namespace (backend #{index})" do
      backend = instance_exec(&build)
      run_a = scoped(backend, "run-a")
      ref = run_a.store("run A private bytes")
      inner = ref.delete_prefix("run-a:")

      expect(run_a.fetch(ref)).to eq("run A private bytes")
      expect(scoped(backend, "run-b").fetch("run-b:#{inner}")).to be_nil
      expect(scoped(backend, "run-b").fetch(ref)).to be_nil
      expect(scoped(backend, "child", readable: ["run-a"]).fetch(ref)).to eq("run A private bytes")
      expect(scoped(backend, "run-b").vouches?).to be(true)
      expect(backend.stored_by?(inner, "run-a")).to be(true)
      expect(backend.stored_by?(inner, "run-b")).to be(false)
    end
  end

  it "keeps a file store's reads inside its directory and its tenant" do
    File.write(File.join(@dir, "..", "secret.txt"), "TOP-SECRET")
    store = Smith::Artifacts::File.new(dir: @dir)
    ref = scoped(store, "run-a").store("mine")

    expect(scoped(store, "run-a").fetch("run-a:../secret.txt")).to be_nil
    ["../secret.txt", ".", "a/b", "x\u0000y"].each { |bad| expect(store.fetch(bad)).to be_nil, bad.inspect }
    expect(store.fetch(ref.delete_prefix("run-a:"))).to eq("mine")
    inner = ref.delete_prefix("run-a:")
    store.delete(inner)
    expect([store.fetch(inner), File.exist?(File.join(@dir, "#{inner}.meta"))]).to eq([nil, false])

    tenant_a = Smith::Artifacts::File.new(dir: @dir, namespace: "tenant-a")
    tenant_b = Smith::Artifacts::File.new(dir: @dir, namespace: "tenant-b")
    stored = tenant_a.store("tenant A data", execution_namespace: "run-a")
    expect(tenant_b.fetch(stored)).to be_nil
    expect(tenant_a.fetch(stored)).to eq("tenant A data")
  ensure
    FileUtils.rm_f(File.join(@dir, "..", "secret.txt"))
  end

  it "shares identical bytes between runs only with the runs that stored them" do
    backend = Smith::Artifacts::Memory.new
    ref_a = scoped(backend, "run-a").store("same bytes")
    guessed = "run-b:#{Digest::SHA256.hexdigest("same bytes")}"

    expect(scoped(backend, "run-b").fetch(guessed)).to be_nil
    ref_b = scoped(backend, "run-b").store("same bytes")
    expect(scoped(backend, "run-b").fetch(ref_b)).to eq("same bytes")
    expect(ref_a.delete_prefix("run-a:")).to eq(ref_b.delete_prefix("run-b:"))
  end
end
