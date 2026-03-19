# frozen_string_literal: true

RSpec.describe "Smith tracing runtime behavior" do
  let(:memory_trace_class) { require_const("Smith::Trace::Memory") }
  let(:logger_trace_class) { require_const("Smith::Trace::Logger") }
  let(:open_telemetry_trace_class) { require_const("Smith::Trace::OpenTelemetry") }
  let(:tool_class) { require_const("Smith::Tool") }
  let(:workflow_class) { require_const("Smith::Workflow") }

  def with_trace_adapter(adapter)
    original_adapter = Smith.config.trace_adapter

    Smith.configure { |config| config.trace_adapter = adapter }
    Smith::Trace.reset!
    yield
  ensure
    Smith.configure { |config| config.trace_adapter = original_adapter }
    Smith::Trace.reset!
  end

  def with_trace_fields(fields)
    original_fields = Smith.config.trace_fields

    Smith.configure { |config| config.trace_fields = fields }
    yield
  ensure
    Smith.configure { |config| config.trace_fields = original_fields }
  end

  def with_configured_logger(logger)
    original_logger = Smith.config.logger

    Smith.configure { |config| config.logger = logger }
    yield
  ensure
    Smith.configure { |config| config.logger = original_logger }
  end

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

  it "filters transition trace fields through the configured field allowlist" do
    adapter = memory_trace_class.new

    with_trace_adapter(adapter) do
      with_trace_fields(transition: %i[transition to]) do
        Smith::Trace.record(type: :transition, data: { transition: :finish, from: :idle, to: :done })
      end
    end

    expect(adapter.traces).to eq([
                                   {
                                     type: :transition,
                                     data: { transition: :finish, to: :done }
                                   }
                                 ])
  end

  it "filters tool-call trace fields through the configured field allowlist" do
    adapter = memory_trace_class.new

    with_trace_adapter(adapter) do
      with_trace_fields(tool_call: %i[tool]) do
        Smith::Trace.record(type: :tool_call, data: { tool: "search", duration: 12 })
      end
    end

    expect(adapter.traces).to eq([
                                   {
                                     type: :tool_call,
                                     data: { tool: "search" }
                                   }
                                 ])
  end

  it "ignores unknown field names in trace field configuration" do
    adapter = memory_trace_class.new

    with_trace_adapter(adapter) do
      with_trace_fields(transition: %i[transition missing_field]) do
        Smith::Trace.record(type: :transition, data: { transition: :finish, from: :idle, to: :done })
      end
    end

    expect(adapter.traces).to eq([
                                   {
                                     type: :transition,
                                     data: { transition: :finish }
                                   }
                                 ])
  end

  it "leaves unconfigured trace types unchanged" do
    adapter = memory_trace_class.new

    with_trace_adapter(adapter) do
      with_trace_fields(transition: %i[transition]) do
        Smith::Trace.record(type: :tool_call, data: { tool: "search", duration: 12 })
      end
    end

    expect(adapter.traces).to eq([
                                   {
                                     type: :tool_call,
                                     data: { tool: "search", duration: 12 }
                                   }
                                 ])
  end

  it "emits a transition trace after a successful workflow step completes" do
    adapter = memory_trace_class.new

    workflow = with_stubbed_class("SpecTraceWorkflow", workflow_class) do
      initial_state :idle
      state :done

      transition :finish, from: :idle, to: :done
    end.new

    with_trace_adapter(adapter) do
      result = workflow.run!

      expect(result.state).to eq(:done)
    end

    expect(adapter.traces).to include(
      {
        type: :transition,
        data: { transition: :finish, from: :idle, to: :done }
      }
    )
  end

  it "supports a class-configured trace adapter for runtime emission" do
    workflow = with_stubbed_class("SpecTraceClassAdapterWorkflow", workflow_class) do
      initial_state :idle
      state :done

      transition :finish, from: :idle, to: :done
    end.new

    with_trace_adapter(memory_trace_class) do
      result = workflow.run!

      expect(result.state).to eq(:done)
      expect(Smith::Trace.resolve_adapter).to be_a(memory_trace_class)
      expect(Smith::Trace.resolve_adapter.traces).to include(
        {
          type: :transition,
          data: { transition: :finish, from: :idle, to: :done }
        }
      )
    end
  end

  it "records runtime-emitted traces through the built-in logger adapter class" do
    observed = []
    logger = Object.new
    logger.define_singleton_method(:info) do |message|
      observed << message
    end

    workflow = with_stubbed_class("SpecTraceLoggerAdapterWorkflow", workflow_class) do
      initial_state :idle
      state :done

      transition :finish, from: :idle, to: :done
    end.new

    with_configured_logger(logger) do
      with_trace_adapter(logger_trace_class) do
        result = workflow.run!
        expect(result.state).to eq(:done)
      end
    end

    expect(observed).to eq([
                             "[Smith::Trace] transition: #{{
                               transition: :finish,
                               from: :idle,
                               to: :done
                             }.inspect}"
                           ])
  end

  it "applies content filtering in the built-in logger adapter output" do
    observed = []
    logger = Object.new
    original_value = Smith.config.trace_content

    logger.define_singleton_method(:info) do |message|
      observed << message
    end

    Smith.configure { |config| config.trace_content = :redacted }

    with_configured_logger(logger) do
      logger_trace_class.new.record(type: :tool_call, data: { tool: "search", content: "secret" })
    end

    expect(observed).to eq([
                             "[Smith::Trace] tool_call: #{{
                               tool: "[REDACTED]",
                               content: "[REDACTED]"
                             }.inspect}"
                           ])
  ensure
    Smith.configure { |config| config.trace_content = original_value }
  end

  it "emits a tool-call trace after tool execution" do
    adapter = memory_trace_class.new

    traced_tool = with_stubbed_class("SpecTraceTool", tool_class) do
      def perform(**kwargs)
        kwargs
      end
    end

    result = nil
    with_trace_adapter(adapter) do
      result = traced_tool.new.execute(context: {}, query: "status")
    end

    expect(result).to eq({ context: {}, query: "status" })
    tool_traces = adapter.traces.select { |t| t[:type] == :tool_call }
    expect(tool_traces.length).to eq(1)
    expect(tool_traces.first[:data][:tool]).to eq(traced_tool.new.name)
    expect(tool_traces.first[:data]).to have_key(:duration)
  end

  it "respects transition trace toggles during workflow runtime emission" do
    adapter = memory_trace_class.new
    original_value = Smith.config.trace_transitions

    workflow = with_stubbed_class("SpecTraceToggleWorkflow", workflow_class) do
      initial_state :idle
      state :done

      transition :finish, from: :idle, to: :done
    end.new

    Smith.configure { |config| config.trace_transitions = false }

    with_trace_adapter(adapter) do
      result = workflow.run!
      expect(result.state).to eq(:done)
    end

    expect(adapter.traces).to eq([])
  ensure
    Smith.configure { |config| config.trace_transitions = original_value }
  end

  it "does not let trace adapter failures break workflow execution" do
    failing_adapter = Object.new
    failing_adapter.define_singleton_method(:record) do |**_kwargs|
      raise "trace sink unavailable"
    end

    workflow = with_stubbed_class("SpecTraceFailureWorkflow", workflow_class) do
      initial_state :idle
      state :done

      transition :finish, from: :idle, to: :done
    end.new

    expect do
      with_trace_adapter(failing_adapter) do
        result = workflow.run!
        expect(result.state).to eq(:done)
      end
    end.not_to raise_error
  end

  it "does not let trace adapter failures break tool execution" do
    failing_adapter = Object.new
    failing_adapter.define_singleton_method(:record) do |**_kwargs|
      raise "trace sink unavailable"
    end

    traced_tool = with_stubbed_class("SpecTraceFailureTool", tool_class) do
      def perform(**kwargs)
        kwargs.fetch(:value)
      end
    end

    result = nil
    expect do
      with_trace_adapter(failing_adapter) do
        result = traced_tool.new.execute(context: {}, value: "ok")
      end
    end.not_to raise_error

    expect(result).to eq("ok")
  end

  it "records traces through the built-in OpenTelemetry adapter when the dependency surface is available" do
    span = Object.new
    observed_attributes = []
    span.define_singleton_method(:set_attribute) do |key, value|
      observed_attributes << [key, value]
    end

    tracer = Object.new
    observed_span_names = []
    tracer.define_singleton_method(:in_span) do |name, &block|
      observed_span_names << name
      block.call(span)
    end

    provider = Object.new
    provider.define_singleton_method(:tracer) do |name, version|
      tracer
    end

    stub_const("OpenTelemetry", Module.new)
    allow(OpenTelemetry).to receive(:tracer_provider).and_return(provider)
    allow_any_instance_of(open_telemetry_trace_class).to receive(:require)
      .with("opentelemetry-api").and_return(true)

    workflow = with_stubbed_class("SpecTraceOpenTelemetryWorkflow", workflow_class) do
      initial_state :idle
      state :done

      transition :finish, from: :idle, to: :done
    end.new

    with_trace_adapter(open_telemetry_trace_class) do
      result = workflow.run!
      expect(result.state).to eq(:done)
    end

    expect(observed_span_names).to eq(["smith.transition"])
    expect(observed_attributes).to contain_exactly(
      ["smith.transition", "finish"],
      ["smith.from", "idle"],
      ["smith.to", "done"]
    )
  end

  it "degrades safely when the OpenTelemetry dependency is unavailable" do
    observed_warnings = []
    logger = Object.new
    logger.define_singleton_method(:warn) do |message|
      observed_warnings << message
    end

    allow_any_instance_of(open_telemetry_trace_class).to receive(:require)
      .with("opentelemetry-api").and_raise(LoadError)

    workflow = with_stubbed_class("SpecTraceOpenTelemetryMissingDependencyWorkflow", workflow_class) do
      initial_state :idle
      state :done

      transition :finish, from: :idle, to: :done
    end.new

    expect do
      with_configured_logger(logger) do
        with_trace_adapter(open_telemetry_trace_class) do
          result = workflow.run!
          expect(result.state).to eq(:done)
        end
      end
    end.not_to raise_error

    expect(observed_warnings).to eq([
                                      "Smith::Trace::OpenTelemetry requires the opentelemetry-api gem. " \
                                      "Add it to your Gemfile to enable OpenTelemetry tracing."
                                    ])
  end
end
