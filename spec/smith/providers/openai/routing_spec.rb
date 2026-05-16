# frozen_string_literal: true

RSpec.describe Smith::Providers::OpenAI::Routing do
  it "is prepended onto RubyLLM::Providers::OpenAI at load time" do
    expect(RubyLLM::Providers::OpenAI.ancestors).to include(described_class)
  end

  describe "Smith.config.openai_api_mode validation" do
    after { Smith.config.openai_api_mode = :off }

    it "accepts :off" do
      expect { Smith.config.openai_api_mode = :off }.not_to raise_error
    end

    it "accepts :auto" do
      expect { Smith.config.openai_api_mode = :auto }.not_to raise_error
    end

    it "raises ArgumentError on invalid values" do
      expect { Smith.config.openai_api_mode = :invalid }.to raise_error(ArgumentError, /must be :off or :auto/)
    end
  end

  describe "dispatch logic" do
    # Use a minimal stub OpenAI provider to test the dispatcher without
    # making real HTTP calls. The instance_of? check in the prepend
    # ensures we only act on the canonical RubyLLM::Providers::OpenAI
    # class (not subclasses); tests have to use a real instance.

    before(:each) do
      RubyLLM.configure { |c| c.openai_api_key = "test-key" }
    end

    let(:provider) { RubyLLM::Providers::OpenAI.new(RubyLLM.config) }

    it "does not raise NotImplementedError when params[:openai_api_mode] is absent (falls through to super)" do
      # When the routing trigger isn't present, the prepend must call
      # super and let RubyLLM handle the request normally. We assert
      # by absence of the routing-specific NotImplementedError; any
      # other error (e.g., nil model from a minimal test invocation)
      # is fine — it means we reached RubyLLM's code, not Smith's.
      expect do
        described_class.instance_method(:complete).bind(provider).call(
          [], tools: {}, temperature: 1.0, model: nil, params: {}
        )
      end.not_to raise_error(NotImplementedError, /not yet vendored/)
    end

    it "raises NotImplementedError when routing is requested but the Responses adapter isn't loaded" do
      # The Responses module is vendored (PR #770 at pinned SHA) and loads
      # by default. This test hides the constant to exercise the routing
      # prepend's graceful fallback for the case where a host pins an
      # older Smith without the vendored adapter, or explicitly unloads
      # the vendor for testing. The prepend detects the missing adapter
      # and raises a clear NotImplementedError.
      hide_const("Smith::Providers::OpenAI::Responses") if defined?(Smith::Providers::OpenAI::Responses)

      expect do
        described_class.instance_method(:complete).bind(provider).call(
          [], tools: {}, temperature: 1.0, model: nil,
          params: { openai_api_mode: :responses }
        )
      end.to raise_error(NotImplementedError, /Responses.*not yet vendored/)
    end

    it "accepts string-keyed openai_api_mode (RubyLLM may serialize params with string keys)" do
      hide_const("Smith::Providers::OpenAI::Responses") if defined?(Smith::Providers::OpenAI::Responses)

      expect do
        described_class.instance_method(:complete).bind(provider).call(
          [], tools: {}, temperature: 1.0, model: nil,
          params: { "openai_api_mode" => "responses" }
        )
      end.to raise_error(NotImplementedError)
    end
  end
end
