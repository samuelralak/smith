# frozen_string_literal: true

RSpec.describe "Smith trace attribution" do
  let(:memory_trace_class) { require_const("Smith::Trace::Memory") }

  def with_trace_adapter(adapter)
    original_adapter = Smith.config.trace_adapter

    Smith.configure { |config| config.trace_adapter = adapter }
    Smith::Trace.reset!
    yield
  ensure
    Smith.configure { |config| config.trace_adapter = original_adapter }
    Smith::Trace.reset!
  end

  def with_setting(name, value)
    original = Smith.config.public_send(name)

    Smith.configure { |config| config.public_send("#{name}=", value) }
    yield
  ensure
    Smith.configure { |config| config.public_send("#{name}=", original) }
  end

  it "merges ambient attribution fields into recorded payloads" do
    adapter = memory_trace_class.new

    with_trace_adapter(adapter) do
      Smith::Attribution.with(execution_key: "run-9", transition: :fetch) do
        Smith::Trace.record(type: :transition, data: { state: :running })
      end
    end

    expect(adapter.traces).to eq([
                                   { type: :transition,
                                     data: { execution_key: "run-9", transition: :fetch, state: :running } }
                                 ])
  end

  it "lets caller-supplied keys win over attribution keys" do
    adapter = memory_trace_class.new

    with_trace_adapter(adapter) do
      Smith::Attribution.with(transition: :ambient) do
        Smith::Trace.record(type: :transition, data: { transition: :explicit })
      end
    end

    expect(adapter.traces).to eq([{ type: :transition, data: { transition: :explicit } }])
  end

  it "records unchanged payloads when no attribution is ambient" do
    adapter = memory_trace_class.new

    with_trace_adapter(adapter) do
      Smith::Trace.record(type: :transition, data: { state: :idle })
    end

    expect(adapter.traces).to eq([{ type: :transition, data: { state: :idle } }])
  end

  it "can be disabled with trace_attribution" do
    adapter = memory_trace_class.new

    with_trace_adapter(adapter) do
      with_setting(:trace_attribution, false) do
        Smith::Attribution.with(execution_key: "run-10") do
          Smith::Trace.record(type: :transition, data: { state: :running })
        end
      end
    end

    expect(adapter.traces).to eq([{ type: :transition, data: { state: :running } }])
  end

  it "keeps a configured trace_fields allowlist authoritative over attribution keys" do
    adapter = memory_trace_class.new

    with_trace_adapter(adapter) do
      with_setting(:trace_fields, { transition: %i[state transition] }) do
        Smith::Attribution.with(execution_key: "run-11", transition: :fetch) do
          Smith::Trace.record(type: :transition, data: { state: :running })
        end
      end
    end

    expect(adapter.traces).to eq([
                                   { type: :transition, data: { transition: :fetch, state: :running } }
                                 ])
  end
end
