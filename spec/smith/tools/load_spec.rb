# frozen_string_literal: true

require "open3"
require "rbconfig"

RSpec.describe "Smith::ToolCaptureFailed direct loading" do
  let(:library_path) { File.expand_path("../../../lib", __dir__) }

  it "loads the strict capture error directly" do
    stdout, stderr, status = Open3.capture3(
      RbConfig.ruby,
      "-I",
      library_path,
      "-e",
      'require "smith/tool_capture_failed"; puts Smith::ToolCaptureFailed < Smith::Error'
    )

    expect(status).to be_success, stderr
    expect(stdout).to eq("true\n")
  end
end
