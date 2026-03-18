# frozen_string_literal: true

RSpec.describe "Smith tracing runtime behavior" do
  let(:memory_trace_class) { require_const("Smith::Trace::Memory") }

  it "records structural trace data by default while omitting content fields" do
    adapter = memory_trace_class.new

    adapter.record(type: :transition, data: { state: :graphing, content: "secret", response: "hidden" })

    expect(adapter.traces).to eq([{ type: :transition, data: { state: :graphing } }])
  end

  it "redacts string content fields when trace_content is :redacted" do
    adapter = memory_trace_class.new
    original_value = Smith.config.trace_content

    Smith.configure { |config| config.trace_content = :redacted }

    adapter.record(type: :tool_call, data: { content: "secret", prompt: "question", attempts: 2 })

    expect(adapter.traces).to eq([
      {
        type: :tool_call,
        data: { content: "[REDACTED]", prompt: "[REDACTED]", attempts: 2 }
      }
    ])
  ensure
    Smith.configure { |config| config.trace_content = original_value }
  end

  it "retains full content when trace_content is true" do
    adapter = memory_trace_class.new
    original_value = Smith.config.trace_content

    Smith.configure { |config| config.trace_content = true }

    adapter.record(type: :cost, data: { content: "visible", cost: 1.25 })

    expect(adapter.traces).to eq([{ type: :cost, data: { content: "visible", cost: 1.25 } }])
  ensure
    Smith.configure { |config| config.trace_content = original_value }
  end

  it "honors structural trace type toggles" do
    adapter = memory_trace_class.new
    original_value = Smith.config.trace_tool_calls

    Smith.configure { |config| config.trace_tool_calls = false }

    adapter.record(type: :tool_call, data: { tool: "search" })

    expect(adapter.traces).to eq([])
  ensure
    Smith.configure { |config| config.trace_tool_calls = original_value }
  end
end
