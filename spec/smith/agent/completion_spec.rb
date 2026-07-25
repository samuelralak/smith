# frozen_string_literal: true

RSpec.describe Smith::Agent::Completion do
  let(:message_class) { Struct.new(:role, :content, :input_tokens, :output_tokens) }

  it "aggregates every assistant response in one tool loop" do
    final = message_class.new(role: :assistant, content: "complete", input_tokens: 5, output_tokens: 7)
    messages = [
      message_class.new(role: :assistant, content: nil, input_tokens: 2, output_tokens: 3),
      message_class.new(role: :tool, content: "evidence", input_tokens: nil, output_tokens: nil),
      final
    ]

    completion = described_class.from_messages(response: final, messages: messages)

    expect(completion.content).to eq("complete")
    expect(completion.input_tokens).to eq(7)
    expect(completion.output_tokens).to eq(10)
    expect(completion.provider_usages.map(&:to_h)).to eq(
      [
        { input_tokens: 2, output_tokens: 3 },
        { input_tokens: 5, output_tokens: 7 }
      ]
    )
  end

  it "keeps aggregate usage unknown while retaining trustworthy response usage" do
    final = message_class.new(role: :assistant, content: "complete", input_tokens: 5, output_tokens: 7)
    messages = [
      message_class.new(role: :assistant, content: nil, input_tokens: nil, output_tokens: 3),
      final
    ]

    completion = described_class.from_messages(response: final, messages: messages)

    expect(completion.input_tokens).to be_nil
    expect(completion.output_tokens).to be_nil
    expect(completion.usage_complete).to be(false)
    expect(completion.provider_usages.map(&:to_h)).to eq(
      [
        { input_tokens: 5, output_tokens: 7 }
      ]
    )
  end

  it "falls back to the returned response when a chat does not expose new messages" do
    final = message_class.new(role: :assistant, content: "complete", input_tokens: 5, output_tokens: 7)

    completion = described_class.from_messages(response: final, messages: [])

    expect(completion.input_tokens).to eq(5)
    expect(completion.output_tokens).to eq(7)
    expect(completion.provider_usages.map(&:total_tokens)).to eq([12])
  end
end
