# frozen_string_literal: true

RSpec.describe "Smith configuration contract" do
  it "exposes the top-level configure API used throughout the architecture" do
    expect(Smith).to respond_to(:configure)
  end

  it "yields a configuration object with the documented artifact and trace settings" do
    yielded_config = nil

    Smith.configure do |config|
      yielded_config = config
    end

    expect(yielded_config).not_to be_nil

    %i[
      artifact_store=
      artifact_retention=
      artifact_encryption=
      artifact_tenant_isolation=
      trace_adapter=
      trace_transitions=
      trace_tool_calls=
      trace_token_usage=
      trace_cost=
      trace_content=
      trace_retention=
      trace_tenant_isolation=
    ].each do |method_name|
      expect(yielded_config).to respond_to(method_name), "expected config to implement ##{method_name}"
    end
  end
end
