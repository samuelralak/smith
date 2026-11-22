# frozen_string_literal: true

require "digest"
require "open3"
require "smith/scope"

RSpec.describe Smith::Scope do
  let(:example) { { tenant: "ten_0193", project: "prj_ticket_triage" } }

  it "is a frozen Hash of frozen UTF-8 Strings, Symbol keys converted, keys in order" do
    scope = described_class.build(example)

    expect(scope).to eq("project" => "prj_ticket_triage", "tenant" => "ten_0193")
    expect(scope.keys).to eq(%w[project tenant])
    expect(scope).to be_frozen
    expect((scope.keys + scope.values).map { [_1.frozen?, _1.encoding] }.uniq).to eq([[true, Encoding::UTF_8]])
    expect(described_class.build(scope)).to eq(scope)
    expect(described_class.build({})).to eq({})
  end

  it "keeps the caller's strings out of reach" do
    value = +"ten_0193"
    scope = described_class.build("tenant" => value)
    value << "x"

    expect(scope["tenant"]).to eq("ten_0193")
  end

  it "holds at most 8 pairs" do
    eight = (1..8).to_h { |index| ["k#{index}", "v"] }

    expect(described_class.build(eight).size).to eq(8)
    expect { described_class.build(eight.merge("k9" => "v")) }.to raise_error(Smith::ScopeInvalid, /at most 8 pairs/)
  end

  it "refuses a value that is not a String of 1 to 256 bytes of UTF-8" do
    expect(described_class.build(tenant: "x" * 256)["tenant"].bytesize).to eq(256)
    [17, :tenant, nil, "", "x" * 257, "\xff", ["ten"]].each do |value|
      expect { described_class.build(tenant: value) }.to raise_error(Smith::ScopeInvalid, /"tenant"/)
    end
  end

  it "refuses a bad key" do
    expect(described_class.build("a#{"b" * 63}" => "v").keys.first.length).to eq(64)
    ["Tenant", "1tenant", "_tenant", "ten-ant", "", "a#{"b" * 64}", "ténant", 7, nil].each do |key|
      expect { described_class.build(key => "v") }.to raise_error(Smith::ScopeInvalid, /scope keys/)
    end
  end

  it "refuses a key given twice once Symbols are converted, and anything that is not a Hash" do
    expect { described_class.build(tenant: "a", "tenant" => "b") }.to raise_error(Smith::ScopeInvalid, /twice/)
    expect { described_class.build([%w[tenant a]]) }.to raise_error(Smith::ScopeInvalid, /Hash/)
    expect { described_class.build(nil) }.to raise_error(Smith::ScopeInvalid)
  end

  it "never names a scope value in its errors" do
    secret = "value-#{"z" * 300}"

    expect { described_class.build(tenant: secret) }.to raise_error(Smith::ScopeInvalid) { |error|
      expect(error.message).not_to include("value-")
    }
    expect(Smith::ScopeInvalid.ancestors).to include(Smith::Error)
  end

  describe ".digest" do
    it "is the first 32 hex digits of SHA-256 of the frame and the scope's canonical JSON" do
      expected = Digest::SHA256.hexdigest(%(smith.evals.scope/1\n{"project":"prj_ticket_triage","tenant":"ten_0193"}))

      expect(described_class.digest(example)).to eq(expected[0, 32])
      expect(described_class.digest(example)).to eq("1fa7322c0ac96a7353fd3115ae313b08")
    end

    it "does not depend on key order or Symbol keys, and refuses what build refuses" do
      expect(described_class.digest("tenant" => "ten_0193", "project" => "prj_ticket_triage"))
        .to eq(described_class.digest(example))
      expect { described_class.digest(tenant: 1) }.to raise_error(Smith::ScopeInvalid)
    end

    # The same digests the reference generator's canonical JSON gives (jcs.py).
    it "is stable across processes" do
      script = <<~RUBY
        require "smith/scope"
        [{ tenant: "ten_0193", project: "prj_ticket_triage" }, { tenant: "t\\u00e9n\\u20ac" }, {}].each do |scope|
          puts Smith::Scope.digest(scope)
        end
      RUBY
      outputs = Array.new(2) do
        stdout, stderr, status = Open3.capture3(RbConfig.ruby, "-I", File.expand_path("../../lib", __dir__), "-e",
                                                script)
        raise stderr unless status.success?

        stdout
      end

      expect(outputs.uniq.size).to eq(1)
      expect(outputs.first.split).to eq(%w[1fa7322c0ac96a7353fd3115ae313b08 f2ecff9a8b21d3089ec1ac970c1a2e57
                                           a88c2cd62317fb174421d1a023818c80])
    end
  end
end
