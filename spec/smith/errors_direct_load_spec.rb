# frozen_string_literal: true

require "English"

RSpec.describe "Smith error classification direct load" do
  it "loads terminal tool error dependencies with smith/errors" do
    output = IO.popen(
      [
        RbConfig.ruby,
        "-I#{File.expand_path("../../lib", __dir__)}",
        "-e",
        'require "smith/errors"; puts Smith::Errors.retry_forbidden?' \
        '(Smith::ToolOutcomeUncertain.new("unknown")) && ' \
        'Smith::Errors.retry_forbidden?(Smith::PersistedFailureInvalid.new("corrupt"))'
      ],
      &:read
    )
    status = $CHILD_STATUS

    expect(status).to be_success
    expect(output).to eq("true\n")
  end
end
