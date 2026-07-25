# frozen_string_literal: true

require "English"

RSpec.describe "Smith split-file direct loading" do
  it "installs the complete Agent class-method surface from smith/agent" do
    script = <<~RUBY
      require "smith/agent"

      modules = [
        Smith::Agent::DynamicConfiguration,
        Smith::Agent::ReservedInputBridge,
        Smith::Agent::ChatConstruction
      ]
      abort "missing Agent extension" unless modules.all? { Smith::Agent.singleton_class < _1 }

      Smith::Agent.model { |_context| "dynamic-model" }
      abort "missing dynamic model" unless Smith::Agent.model_block
    RUBY

    expect(run_child(script)).to be(true)
  end

  it "loads the Normalizer tool-routing collaborator directly" do
    script = <<~RUBY
      require "smith/models/normalizer"
      abort "missing ToolRouting" unless defined?(Smith::Models::ToolRouting)
    RUBY

    expect(run_child(script)).to be(true)
  end

  it "loads and uses the provider-qualified model registry without ActiveSupport" do
    script = <<~RUBY
      require "smith/models"

      profile = Smith::Models::Profile.new(
        model_id: "direct-model",
        provider: "openai",
        thinking_shape: nil,
        accepts_temperature: true,
        tools_with_thinking_native: false,
        tools_with_thinking_route: nil
      )
      Smith::Models.register(profile)

      resolved = Smith::Models.find("direct-model", provider: :openai)
      abort "provider was not normalized" unless resolved.provider == :openai
    RUBY

    expect(run_child(script)).to be(true)
  end

  it "loads model registry errors directly" do
    script = <<~RUBY
      require "smith/models/ambiguous_profile_error"
      require "smith/models/collision_error"

      abort "missing ambiguous error" unless Smith::Models::AmbiguousProfileError < Smith::Error
      abort "missing collision error" unless Smith::Models::CollisionError < Smith::Error
    RUBY

    expect(run_child(script)).to be(true)
  end

  it "loads terminal tool and workflow failure records directly" do
    script = <<~RUBY
      require "smith/tool_failure_notification_failed"
      require "smith/workflow/failure_detail_snapshot"
      require "smith/workflow/failure_record"
      require "smith/workflow/failure_record_restore"
      require "smith/workflow/failure_record_validator"
      require "smith/workflow/failure_reconstructor"

      abort "missing terminal error" unless defined?(Smith::ToolFailureNotificationFailed)
      abort "missing failure detail snapshot" unless defined?(Smith::Workflow::FailureDetailSnapshot)
      abort "missing failure record" unless defined?(Smith::Workflow::FailureRecord)
      abort "missing failure record restore" unless defined?(Smith::Workflow::FailureRecordRestore)
      abort "missing failure record validator" unless defined?(Smith::Workflow::FailureRecordValidator)
      abort "missing failure reconstructor" unless defined?(Smith::Workflow::FailureReconstructor)
    RUBY

    expect(run_child(script)).to be(true)
  end

  def run_child(script)
    ruby = RbConfig.ruby
    lib = File.expand_path("../../lib", __dir__)
    system(ruby, "-I#{lib}", "-e", script, out: File::NULL, err: File::NULL)
  ensure
    warn "child process failed with #{$CHILD_STATUS.inspect}" unless $CHILD_STATUS&.success?
  end
end
