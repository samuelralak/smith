# frozen_string_literal: true

require "smith/evals"

RSpec.describe Smith::Evals::Configuration do
  subject(:config) { described_class.new }

  it "starts from the design's defaults" do
    expect(config.store).to be_nil
    expect(config.dataset_root).to be_nil
    expect(config.dataset_source).to be_nil
    expect(config.host_code_version).to be_nil
    expect(config.cost_unit).to eq("USD")
    expect(config.default_scope).to eq({})
    expect(config.recording).to eq(content: true, max_steps: 256, max_message_bytes: 32_768, max_tool_bytes: 4_096,
                                   max_step_bytes: 262_144, max_trial_bytes: 4_194_304)
  end

  it "merges recording bounds given in part, up to their ceilings, and refuses one past its ceiling" do
    config.recording = { max_steps: 4_096, content: false }

    expect(config.recording).to include(max_steps: 4_096, content: false, max_message_bytes: 32_768)
    expect { config.recording = { max_trial_bytes: (8 * 1024 * 1024) + 1 } }
      .to raise_error(ArgumentError, /max_trial_bytes is an Integer from 1 to 8388608/)
    expect { config.recording = { max_lines: 3 } }.to raise_error(ArgumentError, /unknown recording setting max_lines/)
    expect { config.recording = { content: "yes" } }.to raise_error(ArgumentError, /content is true or false/)
  end

  it "keeps the default scope as a Smith::Scope and refuses one that is not" do
    config.default_scope = { tenant: "ten_0193" }

    expect(config.default_scope).to eq("tenant" => "ten_0193")
    expect { config.default_scope = { "Tenant" => "x" } }.to raise_error(Smith::ScopeInvalid)
  end

  it "refuses a dataset source that cannot be called, and settings of the wrong type" do
    expect { config.dataset_source = "db" }.to raise_error(ArgumentError, /responds to call/)
    expect { config.host_code_version = "x" * 129 }.to raise_error(ArgumentError, /at most 128/)
    expect { config.cost_unit = "" }.to raise_error(ArgumentError, /cost_unit/)
    expect { config.dataset_root = 7 }.to raise_error(ArgumentError, /dataset_root/)
  end

  it "gives each run a frozen copy that later changes never reach" do
    config.host_code_version = "9b27c3f"
    copy = config.frozen_copy
    config.host_code_version = "4e1d0a7"
    config.recording = { max_steps: 10 }

    expect(copy).to be_frozen
    expect(copy.recording).to be_frozen
    expect([copy.host_code_version, copy.recording[:max_steps]]).to eq(["9b27c3f", 256])
    expect { copy.cost_unit = "EUR" }.to raise_error(FrozenError)
  end

  it "is reached through Smith::Evals.configure and Smith::Evals.config" do
    before = Smith::Evals.config.host_code_version
    Smith::Evals.configure { |settings| settings.host_code_version = "abc1234" }

    expect(Smith::Evals.config.host_code_version).to eq("abc1234")
  ensure
    Smith::Evals.config.host_code_version = before
  end
end
