# frozen_string_literal: true

require "digest"
require "json"
require "open3"
require "smith/definitions"

# The digests of definition format 1 (additions design 2.9): every one
# "sha256:" and 64 lowercase hex over a "name/N\n" frame and RFC 8785
# canonical JSON, a single text over its UTF-8 bytes. The reference file was
# computed by a Python script with the slice 1a reference canonical JSON,
# not by Smith, so another language can check the same values.
RSpec.describe "Definition digests" do
  reference = JSON.parse(File.read(File.expand_path("../../fixtures/definitions/reference.json", __dir__)))
  entries = reference.fetch("documents").to_h { [_1.fetch("name"), _1] }

  let(:digests) { Smith::Definitions.const_get(:Digests) }

  def parse(document) = Smith::Definitions.parse(document)

  entries.each do |name, entry|
    it "gives #{name} the digests computed independently" do
      doc = parse(entry.fetch("document"))
      body = digests.body(doc.to_h)

      expect([doc.digest, doc.prompt_digest, doc.component_versions])
        .to eq(entry.values_at("digest", "prompt_digest", "component_versions"))
      expect(Smith::CanonicalJSON.generate(body)).to eq(entry.fetch("canonical_body"))
      expect(digests.agent(body)).to eq(entry.fetch("agent_digest"))
      expect(digests.workflow(doc.digest)).to eq(entry.fetch("workflow_digest"))
      expect(digests.workflow(doc.digest, base_identity: reference.fetch("base_identity")))
        .to eq(entry.fetch("workflow_digest_with_base"))
    end
  end

  # JSON.stringify as JavaScript writes it: members in the order given,
  # numbers and strings as ECMAScript writes them, which RFC 8785 takes.
  def stringify(value)
    case value
    when Hash then "{#{value.map { |key, item| "#{Smith::CanonicalJSON.generate(key)}:#{stringify(item)}" }.join(",")}}"
    when Array then "[#{value.map { stringify(_1) }.join(",")}]"
    else Smith::CanonicalJSON.generate(value)
    end
  end

  # What a host stores comes back as another writer wrote it: Smith's own
  # canonical JSON, JavaScript's JSON.stringify, Postgres jsonb (numbers
  # without an exponent, as canonical JSON writes them) or Ruby's json.
  it "reads every reference document back, fresh and stored, from each form a store may write" do
    entries.each do |name, entry|
      doc = parse(entry.fetch("document"))
      forms = [entry.fetch("canonical_body"), Smith::CanonicalJSON.generate(doc.to_h), stringify(doc.to_h),
               JSON.generate(doc.to_h), JSON.pretty_generate(doc.to_h)]

      forms.product([false, true]).each do |text, stored|
        again = Smith::Definitions.parse(text, stored:)
        expect([again.digest, Smith::CanonicalJSON.generate(digests.body(again.to_h))])
          .to eq([doc.digest, entry.fetch("canonical_body")]), "#{name}, stored: #{stored}"
      end
    end
  end

  it "reproduces the slice 1a model comparison examples' subject digests, with_llm making the variant" do
    base = parse(entries.fetch("ticket-triage").fetch("document"))
    sonnet = base.with_llm(provider: "anthropic", model: "claude-sonnet-4-6",
                           settings: { temperature: 0, max_output_tokens: 200 })

    expect(base.digest).to eq("sha256:a042de869c3ead5d6221dd2c75e392087348d47db514e79fdabdeef67f33f349")
    expect(sonnet.digest).to eq("sha256:198a512896be5299c6d0622b91f77dbfc459d39763ff09a31b981630e701495c")
    expect([base.prompt_digest, sonnet.prompt_digest].uniq)
      .to eq(["sha256:e5fd366e5c4f95e039f40f23387ca10da53066f7e0fdf6343880bf5b576f6bad"])
    expect(digests.workflow(base.digest))
      .to eq("sha256:926a6f9848edd5c561d8196046d234998bfa945abb203b56d333f6a9ddc13dda")
    expect(digests.workflow(sonnet.digest))
      .to eq("sha256:14049901628125ef38df600436b4c18a858e0712be0f45d104a2aea5cee6f7e6")
    expect(sonnet.component_versions).to eq(
      "triage.rules" => "sha256:58811c83595cb45604d77565e0107ba073d705f3d62b1bcc7edbcd36b0bf1bd3",
      "triage.case" => "sha256:039fc78905b0e4dd3a65e9f2878d685bce153acdb54e5c9964187eca7dc6ef30"
    )
  end

  # Each model the slice 1a comparison examples run is a variant with_llm
  # makes, so the published records hold no setting Smith refuses.
  it "makes every variant of the published model comparison with with_llm" do
    identity = JSON.parse(File.read(File.expand_path("../../fixtures/evals/identity_reference.json", __dir__)))
    base = parse(entries.fetch("ticket-triage").fetch("document"))
    variants = identity.fetch("records").filter_map { _1.dig("variant", "llm") }

    expect(variants.map { _1.fetch("model") }).to eq(%w[claude-haiku-4-5 claude-opus-4-7 claude-sonnet-4-6])
    variants.each do |llm|
      variant = base.with_llm(**llm.transform_keys(&:to_sym))
      expect([variant.prompt_digest, variant.component_versions]).to eq([base.prompt_digest, base.component_versions])
    end
  end

  it "frames each digest as the design says" do
    doc = parse(entries.fetch("job-triage").fetch("document"))
    body = doc.to_h
    sha = ->(text) { "sha256:#{Digest::SHA256.hexdigest(text)}" }

    expect(doc.digest).to eq(sha.call("smith.definition/1\n#{Smith::CanonicalJSON.generate(body)}"))
    expect(doc.prompt_digest)
      .to eq(sha.call("smith.definition_prompt/1\n#{Smith::CanonicalJSON.generate(body.except("llm"))}"))
    expect(digests.agent(body)).to eq(sha.call("smith.definition_agent/1\n#{Smith::CanonicalJSON.generate(body)}"))
    expect(digests.workflow(doc.digest, base_identity: "b"))
      .to eq(sha.call("smith.definition_workflow/1\n{\"base_identity\":\"b\",\"document\":\"#{doc.digest}\"}"))
    expect(doc.component_versions.fetch("triage.case"))
      .to eq(sha.call("The person:\n{{person_summary}}\n\nThe posting:\n{{posting}}"))
    expect([doc.digest, doc.prompt_digest, *doc.component_versions.values]).to all(match(/\Asha256:\h{64}\z/))
  end

  it "gives frozen digests, so no caller can change a document's identity" do
    doc = parse(entries.fetch("job-triage").fetch("document"))
    body = digests.body(doc.to_h)

    expect([doc.digest, doc.prompt_digest, *doc.component_versions.values, digests.agent(body),
            digests.workflow(doc.digest, base_identity: "b")]).to all(be_frozen)
  end

  # Smith checks a workflow's definition digest on every restore, so one
  # that held the execution semantics version would strand every waiting
  # definition run after a Smith release (design 2.9, S5b).
  it "keeps every digest when Smith's execution semantics version moves" do
    document = entries.fetch("job-triage").fetch("document")
    digests_of = lambda do
      doc = parse(document)
      [doc.digest, doc.prompt_digest, digests.agent(digests.body(doc.to_h)), digests.workflow(doc.digest)]
    end
    before = digests_of.call
    stub_const("Smith::EXECUTION_SEMANTICS_VERSION", "#{Smith::EXECUTION_SEMANTICS_VERSION}9")

    expect(digests_of.call).to eq(before)
    expect(before.last).to eq(entries.fetch("job-triage").fetch("workflow_digest"))
  end

  describe "what a digest covers" do
    let(:edge) { entries.fetch("edge-cases").fetch("document") }
    let(:doc) { parse(edge) }

    # Every scalar in the document, by JSON Pointer.
    def leaves(value, path = "")
      case value
      when Hash then value.flat_map { |key, item| leaves(item, "#{path}/#{key}") }
      when Array then value.each_with_index.flat_map { |item, index| leaves(item, "#{path}/#{index}") }
      else [path]
      end
    end

    def changed(value, path)
      copy = JSON.parse(JSON.generate(value))
      *parents, last = path.split("/").drop(1).map { _1.match?(/\A\d+\z/) ? _1.to_i : _1 }
      holder = parents.reduce(copy) { |node, key| node[key] }
      holder[last] = other(holder[last])
      copy
    end

    def other(scalar)
      case scalar
      when String then "#{scalar}x"
      when Integer, Float then (scalar * 2) + 1
      when true, false then !scalar
      else 0
      end
    end

    it "takes in every field but the annotations, at the top and on each prompt component" do
      body = digests.body(doc.to_h)
      paths = leaves(body)

      expect(paths.size).to be > 50
      paths.each do |path|
        other = changed(body, path)
        expect(digests.document(other)).not_to eq(doc.digest), path
        expect(digests.agent(other)).not_to eq(digests.agent(body)), path
        expect(digests.prompt(other) == doc.prompt_digest).to eq(path.start_with?("/llm/")), path
      end
      expect(leaves(edge) - paths).to contain_exactly("/annotations/canvas/x", "/annotations/canvas/y",
                                                      "/annotations/notes/0", "/prompt/0/annotations/note")
    end

    it "keeps an output field named annotations, which is not the format's own" do
      other = JSON.parse(JSON.generate(edge))
      other["outputs"]["properties"]["annotations"]["description"] = "changed"

      expect(parse(other).digest).not_to eq(doc.digest)
    end

    it "does not change with key order, white space, Symbol keys or annotations" do
      shuffled = lambda do |value|
        case value
        when Hash then value.to_a.reverse.to_h { |key, item| [key, shuffled.call(item)] }
        when Array then value.map { shuffled.call(_1) }
        else value
        end
      end
      annotated = JSON.parse(JSON.generate(edge)).merge("annotations" => { "moved" => [1, 2] })
      annotated["prompt"][1]["annotations"] = { "x" => 1 }
      symbolized = JSON.parse(JSON.generate(edge), symbolize_names: true)
      forms = [JSON.pretty_generate(shuffled.call(edge)), "\n #{JSON.generate(edge)}\t", annotated, symbolized]

      forms.each do |form|
        other = parse(form)
        expect([other.digest, other.prompt_digest, other.component_versions])
          .to eq([doc.digest, doc.prompt_digest, doc.component_versions])
      end
      expect(parse(annotated).to_h).to eq(annotated)
    end

    it "changes with a component's text, and only that component's version" do
      other = doc.replace_component("close", "Answer in JSON, nothing else.")

      expect(other.digest).not_to eq(doc.digest)
      expect(other.prompt_digest).not_to eq(doc.prompt_digest)
      expect(other.component_versions.except("close")).to eq(doc.component_versions.except("close"))
      expect(other.component_versions.fetch("close")).not_to eq(doc.component_versions.fetch("close"))
    end
  end

  it "gives the same bytes in another process, locale and time zone" do
    lib = File.expand_path("../../../lib", __dir__)
    script = <<~RUBY
      require "json"
      require "smith/definitions"
      reference = JSON.parse(File.read(ARGV.fetch(0), encoding: "UTF-8"))
      print JSON.generate(reference.fetch("documents").map do |entry|
        doc = Smith::Definitions.parse(entry.fetch("document"))
        [doc.digest, doc.prompt_digest, doc.component_versions]
      end)
    RUBY
    path = File.expand_path("../../fixtures/definitions/reference.json", __dir__)
    expected = entries.values.map { _1.values_at("digest", "prompt_digest", "component_versions") }

    [{ "LC_ALL" => "C", "TZ" => "Pacific/Chatham" }, { "LC_ALL" => "tr_TR.UTF-8", "TZ" => "Asia/Kathmandu" }]
      .each do |env|
        stdout, stderr, status = Open3.capture3(env, RbConfig.ruby, "-I", lib, "-e", script, path)
        expect([status.success?, stderr]).to eq([true, ""])
        expect(JSON.parse(stdout)).to eq(expected)
      end
  end
end
