# frozen_string_literal: true

require "smith/evals"

RSpec.describe Smith::Evals::Actor do
  it "names a person, a service or a policy by the host's id, in its record form" do
    expect(described_class.person("usr_51a8").to_h).to eq("kind" => "person", "id" => "usr_51a8")
    expect(described_class.service("svc_nightly_evals").to_h).to eq("kind" => "service", "id" => "svc_nightly_evals")
    expect(described_class.policy("auto-promote").kind).to eq("policy")
    expect(described_class.person("usr_51a8")).to be_frozen
  end

  it "reads its record form back, and nil as nil" do
    expect(described_class.from_h("kind" => "service", "id" => "svc_1")).to eq(described_class.service("svc_1"))
    expect(described_class.from_h(nil)).to be_nil
  end

  it "refuses another kind, an empty or overlong id and a non-String id" do
    expect { described_class.new(kind: "robot", id: "r") }.to raise_error(ArgumentError, /person, service or policy/)
    expect { described_class.person("") }.to raise_error(ArgumentError, /1 to 256/)
    expect { described_class.person("x" * 257) }.to raise_error(ArgumentError, /1 to 256/)
    expect { described_class.person(42) }.to raise_error(ArgumentError, /1 to 256/)
    expect(described_class.person("é" * 256).id.length).to eq(256)
    expect { described_class.person("\xFF".b) }.to raise_error(ArgumentError, /1 to 256/)
  end

  it "takes an ASCII id in any encoding, as every other check does, and keeps it as UTF-8" do
    actor = described_class.person("usr_1".encode(Encoding::US_ASCII))

    expect([actor.id, actor.id.encoding]).to eq(["usr_1", Encoding::UTF_8])
    expect(described_class.service("svc".b).to_h).to eq("kind" => "service", "id" => "svc")
  end
end
