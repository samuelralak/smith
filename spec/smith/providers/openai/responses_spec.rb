# frozen_string_literal: true

RSpec.describe Smith::Providers::OpenAI::Responses do
  describe ".parse_response_response" do
    let(:response) { Struct.new(:body).new(body) }

    context "when the body carries an error and no output" do
      let(:body) { { "error" => { "message" => "quota exceeded" } } }

      # The error is read before the output, so a reply that failed is not
      # taken for an empty one; it carries its response, as RubyLLM's do.
      it "raises the error with its response" do
        expect { described_class.parse_response_response(response) }
          .to raise_error(RubyLLM::Error, "quota exceeded") { |error| expect(error.response).to be(response) }
      end
    end
  end

  describe ".response_reasoning_text" do
    it "reads a reasoning output's summary, not its content, when it has both" do
      output = { "type" => "reasoning", "summary" => [{ "type" => "summary_text", "text" => "summary" }],
                 "content" => [{ "type" => "output_text", "text" => "content" }] }

      expect(described_class.response_reasoning_text([output])).to eq("summary")
    end
  end

  describe ".format_role" do
    it "sends the system role as developer unless the provider's config asks for system" do
      config = Struct.new(:openai_use_system_role).new(true)
      provider = Object.new.tap { _1.instance_variable_set(:@config, config) }

      expect(described_class.format_role(:system)).to eq("developer")
      expect(described_class.format_role(:system, provider:)).to eq("system")
    end
  end
end
