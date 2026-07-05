# frozen_string_literal: true

require "smith/doctor"

RSpec.describe Smith::Doctor::Checks::ModelsRegistry do
  let(:agent_class) { require_const("Smith::Agent") }

  before do
    @original_models = Smith::Models.all
    Smith::Models.clear!
  end

  after do
    Smith::Models.clear!
    @original_models.each { |profile| Smith::Models.register(profile) }
  end

  it "passes when registered static agent models are covered by inference rules" do
    with_stubbed_class("SpecDoctorCoveredModelAgent", agent_class) do
      register_as :spec_doctor_covered_model_agent
      model "claude-sonnet-4-6"
    end

    report = Smith::Doctor::Report.new
    described_class.run(report)

    check = report.checks.find { |c| c.name == "models.coverage" }
    expect(check.status).to eq(:pass)
    expect(check.message).to include("All registered agents")
  end

  it "passes when a host registers an explicit Smith model profile" do
    Smith::Models.register(
      Smith::Models::Profile.new(
        model_id: "private-model-v1",
        provider: :custom,
        thinking_shape: nil,
        accepts_temperature: true,
        tools_with_thinking_native: false,
        tools_with_thinking_route: nil
      )
    )

    with_stubbed_class("SpecDoctorExplicitProfileAgent", agent_class) do
      register_as :spec_doctor_explicit_profile_agent
      model "private-model-v1"
    end

    report = Smith::Doctor::Report.new
    described_class.run(report)

    check = report.checks.find { |c| c.name == "models.coverage" }
    expect(check.status).to eq(:pass)
  end

  it "warns when registered static agent models have no Smith shaping coverage" do
    with_stubbed_class("SpecDoctorUncoveredModelAgent", agent_class) do
      register_as :spec_doctor_uncovered_model_agent
      model "unrecognized-provider-model"
    end

    report = Smith::Doctor::Report.new
    described_class.run(report)

    check = report.checks.find { |c| c.name == "models.coverage" }
    expect(check.status).to eq(:warn)
    expect(check.message).to include("without explicit profile or matching inference rule")
    expect(check.detail).to include("unrecognized-provider-model")
  end

  it "warns when a static fallback model has no Smith shaping coverage" do
    with_stubbed_class("SpecDoctorUncoveredFallbackModelAgent", agent_class) do
      register_as :spec_doctor_uncovered_fallback_model_agent
      model "claude-sonnet-4-6"
      fallback_models "unrecognized-provider-fallback-model"
    end

    report = Smith::Doctor::Report.new
    described_class.run(report)

    check = report.checks.find { |c| c.name == "models.coverage" }
    expect(check.status).to eq(:warn)
    expect(check.detail).to include("unrecognized-provider-fallback-model")
  end

  it "checks static fallback models even when the primary model is dynamic" do
    with_stubbed_class("SpecDoctorDynamicPrimaryFallbackModelAgent", agent_class) do
      register_as :spec_doctor_dynamic_primary_fallback_model_agent
      model { |_context| "runtime-selected-model" }
      fallback_models "unrecognized-provider-dynamic-fallback-model"
    end

    report = Smith::Doctor::Report.new
    described_class.run(report)

    check = report.checks.find { |c| c.name == "models.coverage" }
    expect(check.status).to eq(:warn)
    expect(check.detail).to include("unrecognized-provider-dynamic-fallback-model")
  end

  it "skips block-form models because they resolve per workflow attempt" do
    with_stubbed_class("SpecDoctorDynamicModelAgent", agent_class) do
      register_as :spec_doctor_dynamic_model_agent
      model { |_context| "unrecognized-runtime-model" }
    end

    report = Smith::Doctor::Report.new
    described_class.run(report)

    check = report.checks.find { |c| c.name == "models.coverage" }
    expect(check.status).to eq(:pass)
  end
end
