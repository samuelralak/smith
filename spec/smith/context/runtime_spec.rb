# frozen_string_literal: true

RSpec.describe "Smith::Context runtime contract" do
  let(:context_class) { require_const("Smith::Context") }

  it "returns the declared session strategy configuration" do
    manager = with_stubbed_class("SpecMaskingContext", context_class) do
      session_strategy :observation_masking, window: 10
    end

    expect(manager.session_strategy).to eq(strategy: :observation_masking, window: 10)
  end

  it "returns the declared persisted workflow context keys in order" do
    manager = with_stubbed_class("SpecPersistContext", context_class) do
      persist :current_findings, :source_urls, :user_context
    end

    expect(manager.persist).to eq(%i[current_findings source_urls user_context])
  end

  it "stores an inject_state formatter that can be called with persisted state" do
    manager = with_stubbed_class("SpecInjectContext", context_class) do
      inject_state do |persisted|
        "summary: #{persisted[:current_findings]}"
      end
    end

    formatter = manager.inject_state

    expect(formatter).to respond_to(:call)
    expect(formatter.call(current_findings: "timeline stable")).to eq("summary: timeline stable")
  end
end
