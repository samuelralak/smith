# frozen_string_literal: true

RSpec.describe "Smith::Workflow run result contract" do
  let(:agent_class) { require_const("Smith::Agent") }
  let(:workflow_class) { require_const("Smith::Workflow") }

  it "returns a result object with the documented workflow summary surface" do
    workflow = with_stubbed_class("SpecRunResultWorkflow", workflow_class) do
      initial_state :idle
      state :done

      transition :go, from: :idle, to: :done
    end.new

    result = workflow.run!

    %i[state output steps total_cost total_tokens].each do |method_name|
      expect(result).to respond_to(method_name), "expected run! result to implement ##{method_name}"
    end
  end

  it "raises MaxTransitionsExceeded and leaves the workflow in its current state" do
    workflow = with_stubbed_class("SpecBoundedWorkflow", workflow_class) do
      initial_state :idle
      state :step_one
      state :step_two
      max_transitions 1

      transition :first, from: :idle, to: :step_one
      transition :second, from: :step_one, to: :step_two
    end.new

    expect { workflow.run! }.to raise_error(require_const("Smith::MaxTransitionsExceeded"))
    expect(workflow.state).to eq(:step_one)
  end

  it "returns immediately when the workflow is already terminal" do
    workflow = with_stubbed_class("SpecImmediatelyTerminalWorkflow", workflow_class) do
      initial_state :idle
    end.new

    result = workflow.run!

    expect(result.state).to eq(:idle)
    expect(result.steps).to eq([])
    expect(result.output).to be_nil
  end

  it "advances through transitions until no further transition exists" do
    workflow = with_stubbed_class("SpecAdvancingWorkflow", workflow_class) do
      initial_state :idle
      state :step_one
      state :step_two
      state :done

      transition :first, from: :idle, to: :step_one
      transition :second, from: :step_one, to: :step_two
      transition :third, from: :step_two, to: :done
    end.new

    result = workflow.run!

    expect(workflow.to_state[:step_count]).to eq(3)
    expect(workflow.state).to eq(:done)
    expect(result.steps.length).to eq(3)
    expect(result.state).to eq(:done)
  end

  it "does not treat the wildcard fail transition as a normal next step" do
    workflow = with_stubbed_class("SpecNoWildcardNormalFlowWorkflow", workflow_class) do
      initial_state :idle
      state :done
      state :failed

      transition :finish, from: :idle, to: :done
    end.new

    result = workflow.run!

    expect(workflow.state).to eq(:done)
    expect(result.state).to eq(:done)
    expect(result.steps.map { |step| step[:transition] }).to eq([:finish])
  end

  it "uses on_success to select the named next transition when multiple transitions share a state" do
    workflow = with_stubbed_class("SpecOnSuccessWorkflow", workflow_class) do
      initial_state :idle
      state :ready
      state :done
      state :alternate_done

      transition :start, from: :idle, to: :ready do
        on_success :finish
      end

      transition :alternate, from: :ready, to: :alternate_done
      transition :finish, from: :ready, to: :done
    end.new

    result = workflow.run!

    expect(workflow.state).to eq(:done)
    expect(result.steps.map { |step| step[:transition] }).to eq(%i[start finish])
  end

  it "returns real last-step output and applies output_schema during workflow agent execution" do
    schema_class = Class.new
    seen_messages = []
    seen_schema = []

    agent = with_stubbed_class("SpecRunResultOutputAgent", agent_class) do
      register_as :spec_run_result_output_agent
      model "gpt-5-mini"
      output_schema schema_class
    end

    fake_chat = Object.new
    fake_chat.define_singleton_method(:add_message) do |message|
      seen_messages << message
    end
    fake_chat.define_singleton_method(:with_schema) do |schema|
      seen_schema << schema
      self
    end
    fake_chat.define_singleton_method(:complete) do
      Struct.new(:content).new({ "status" => "ok" })
    end

    allow(agent).to receive(:chat).and_return(fake_chat)

    workflow = with_stubbed_class("SpecRunResultOutputWorkflow", workflow_class) do
      initial_state :idle
      state :done

      transition :finish, from: :idle, to: :done do
        execute :spec_run_result_output_agent
      end
    end.new

    result = workflow.run!

    expect(result.state).to eq(:done)
    expect(result.output).to eq({ "status" => "ok" })
    expect(result.steps.first[:output]).to eq({ "status" => "ok" })
    expect(seen_schema).to eq([schema_class])
    expect(seen_messages).to eq([])
  end

  it "allows after_completion to hand off an artifact ref through workflow output using the configured backend" do
    backend_stores = []
    original_store = Smith.config.artifact_store

    configured_backend = Object.new
    configured_backend.define_singleton_method(:store) do |data, content_type: "application/octet-stream", execution_namespace: nil|
      backend_stores << { data: data, content_type: content_type, execution_namespace: execution_namespace }
      "backend-ref-#{backend_stores.length}"
    end
    configured_backend.define_singleton_method(:fetch) { |_ref| nil }
    configured_backend.define_singleton_method(:expired) { |retention: nil, execution_namespace: nil| [] }

    Smith.configure do |config|
      config.artifact_store = configured_backend
    end

    agent = with_stubbed_class("SpecArtifactHandoffAgent", agent_class) do
      register_as :spec_artifact_handoff_agent
      model "gpt-5-mini"

      define_method(:after_completion) do |result, _context|
        ref = Smith.artifacts.store(result[:full_report], content_type: "application/json")
        { report_ref: ref, summary: result[:summary] }
      end
    end

    fake_chat = Object.new
    fake_chat.define_singleton_method(:add_message) { |_message| nil }
    fake_chat.define_singleton_method(:complete) do
      Struct.new(:content).new({ full_report: '{"report":"full"}', summary: "brief" })
    end

    allow(agent).to receive(:chat).and_return(fake_chat)

    workflow = with_stubbed_class("SpecArtifactHandoffWorkflow", workflow_class) do
      initial_state :idle
      state :done

      transition :finish, from: :idle, to: :done do
        execute :spec_artifact_handoff_agent
      end
    end.new

    result = workflow.run!
    execution_namespace = workflow.to_state[:execution_namespace]

    expect(result.state).to eq(:done)
    expect(result.output).to eq(
      report_ref: "#{execution_namespace}:backend-ref-1",
      summary: "brief"
    )
    expect(result.steps.first[:output]).to eq(result.output)
    expect(backend_stores.length).to eq(1)
    expect(backend_stores.first[:data]).to eq('{"report":"full"}')
    expect(backend_stores.first[:content_type]).to eq("application/json")
    expect(backend_stores.first[:execution_namespace]).to eq(execution_namespace)
  ensure
    Smith.configure do |config|
      config.artifact_store = original_store
    end
  end

  it "allows bounded agent outputs to remain inline without artifact refs" do
    agent = with_stubbed_class("SpecBoundedInlineOutputAgent", agent_class) do
      register_as :spec_bounded_inline_output_agent
      model "gpt-5-mini"
      data_volume :bounded
    end

    fake_chat = Object.new
    fake_chat.define_singleton_method(:add_message) { |_message| nil }
    fake_chat.define_singleton_method(:complete) do
      Struct.new(:content).new({ summary: "brief", status: "ok" })
    end

    allow(agent).to receive(:chat).and_return(fake_chat)

    workflow = with_stubbed_class("SpecBoundedInlineOutputWorkflow", workflow_class) do
      initial_state :idle
      state :done

      transition :finish, from: :idle, to: :done do
        execute :spec_bounded_inline_output_agent
      end
    end.new

    result = workflow.run!

    expect(result.state).to eq(:done)
    expect(result.output).to eq(summary: "brief", status: "ok")
    expect(result.steps.first[:output]).to eq(result.output)
  end

  it "accepts unbounded agent outputs when they use artifact-ref handoff plus lightweight fields" do
    backend_stores = []
    original_store = Smith.config.artifact_store

    configured_backend = Object.new
    configured_backend.define_singleton_method(:store) do |data, content_type: "application/octet-stream", execution_namespace: nil|
      backend_stores << { data: data, content_type: content_type, execution_namespace: execution_namespace }
      "backend-ref-#{backend_stores.length}"
    end
    configured_backend.define_singleton_method(:fetch) { |_ref| nil }
    configured_backend.define_singleton_method(:expired) { |retention: nil, execution_namespace: nil| [] }

    Smith.configure do |config|
      config.artifact_store = configured_backend
    end

    agent = with_stubbed_class("SpecUnboundedArtifactRefAgent", agent_class) do
      register_as :spec_unbounded_artifact_ref_agent
      model "gpt-5-mini"
      data_volume :unbounded

      define_method(:after_completion) do |result, _context|
        ref = Smith.artifacts.store(result[:full_report], content_type: "application/json")
        { report_ref: ref, summary: result[:summary], status: "ok" }
      end
    end

    fake_chat = Object.new
    fake_chat.define_singleton_method(:add_message) { |_message| nil }
    fake_chat.define_singleton_method(:complete) do
      Struct.new(:content).new({ full_report: '{"report":"full"}', summary: "brief" })
    end

    allow(agent).to receive(:chat).and_return(fake_chat)

    workflow = with_stubbed_class("SpecUnboundedArtifactRefWorkflow", workflow_class) do
      initial_state :idle
      state :done

      transition :finish, from: :idle, to: :done do
        execute :spec_unbounded_artifact_ref_agent
      end
    end.new

    result = workflow.run!
    execution_namespace = workflow.to_state[:execution_namespace]

    expect(result.state).to eq(:done)
    expect(result.output).to eq(
      report_ref: "#{execution_namespace}:backend-ref-1",
      summary: "brief",
      status: "ok"
    )
    expect(result.steps.first[:output]).to eq(result.output)
    expect(backend_stores.length).to eq(1)
    expect(backend_stores.first[:execution_namespace]).to eq(execution_namespace)
  ensure
    Smith.configure do |config|
      config.artifact_store = original_store
    end
  end

  it "routes through on_failure when an unbounded agent output does not include an artifact ref" do
    guardrail_failed = require_const("Smith::GuardrailFailed")

    agent = with_stubbed_class("SpecUnboundedMissingRefAgent", agent_class) do
      register_as :spec_unbounded_missing_ref_agent
      model "gpt-5-mini"
      data_volume :unbounded
    end

    fake_chat = Object.new
    fake_chat.define_singleton_method(:add_message) { |_message| nil }
    fake_chat.define_singleton_method(:complete) do
      Struct.new(:content).new({ summary: "brief", status: "ok" })
    end

    allow(agent).to receive(:chat).and_return(fake_chat)

    workflow = with_stubbed_class("SpecUnboundedMissingRefWorkflow", workflow_class) do
      initial_state :idle
      state :done
      state :failed

      transition :finish, from: :idle, to: :done do
        execute :spec_unbounded_missing_ref_agent
        on_failure :fail
      end
    end.new

    result = workflow.run!

    expect(result.state).to eq(:failed)
    expect(workflow.state).to eq(:failed)
    expect(result.steps.first[:error]).to be_a(guardrail_failed)
    expect(result.steps.first[:error].message).to match(/requires at least one \*_ref key/)
  end

  it "routes through on_failure when an unbounded agent output includes non-scalar inline values" do
    guardrail_failed = require_const("Smith::GuardrailFailed")

    agent = with_stubbed_class("SpecUnboundedNestedInlineAgent", agent_class) do
      register_as :spec_unbounded_nested_inline_agent
      model "gpt-5-mini"
      data_volume :unbounded
    end

    fake_chat = Object.new
    fake_chat.define_singleton_method(:add_message) { |_message| nil }
    fake_chat.define_singleton_method(:complete) do
      Struct.new(:content).new({ report_ref: "opaque-ref", summary: { nested: true } })
    end

    allow(agent).to receive(:chat).and_return(fake_chat)

    workflow = with_stubbed_class("SpecUnboundedNestedInlineWorkflow", workflow_class) do
      initial_state :idle
      state :done
      state :failed

      transition :finish, from: :idle, to: :done do
        execute :spec_unbounded_nested_inline_agent
        on_failure :fail
      end
    end.new

    result = workflow.run!

    expect(result.state).to eq(:failed)
    expect(workflow.state).to eq(:failed)
    expect(result.steps.first[:error]).to be_a(guardrail_failed)
    expect(result.steps.first[:error].message).to match(/requires lightweight scalar values/)
  end
end
