# frozen_string_literal: true

require "smith/doctor"
require "stringio"

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
      fallback_models model: "unrecognized-provider-fallback-model", provider: :custom
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
      model { |_context| { model: "runtime-selected-model", provider: :custom } }
      fallback_models model: "unrecognized-provider-dynamic-fallback-model", provider: :custom
    end

    report = Smith::Doctor::Report.new
    described_class.run(report)

    check = report.checks.find { |c| c.name == "models.coverage" }
    expect(check.status).to eq(:warn)
    expect(check.detail).to include("unrecognized-provider-dynamic-fallback-model")
  end

  it "reports ambiguous unqualified agent models without aborting the doctor run" do
    %i[anthropic bedrock].each do |provider|
      Smith::Models.register(
        Smith::Models::Profile.new(
          model_id: "spec-doctor-shared-provider-model",
          provider: provider,
          thinking_shape: nil,
          accepts_temperature: true,
          tools_with_thinking_native: false,
          tools_with_thinking_route: nil
        )
      )
    end

    with_stubbed_class("SpecDoctorAmbiguousModelAgent", agent_class) do
      register_as :spec_doctor_ambiguous_model_agent
      model "spec-doctor-shared-provider-model"
    end

    report = Smith::Doctor.run(io: StringIO.new)

    ambiguity = report.checks.find { |c| c.name == "models.ambiguity" }
    expect(ambiguity).not_to be_nil
    expect(ambiguity.status).to eq(:fail)
    expect(ambiguity.message).to include("multiple registered providers")
    expect(ambiguity.detail).to include("spec-doctor-shared-provider-model (providers: anthropic, bedrock)")
    expect(report.checks.find { |c| c.name == "models.coverage" }).not_to be_nil
  end

  it "keeps provider-qualified references out of the ambiguity check" do
    %i[anthropic bedrock].each do |provider|
      Smith::Models.register(
        Smith::Models::Profile.new(
          model_id: "spec-doctor-qualified-shared-model",
          provider: provider,
          thinking_shape: nil,
          accepts_temperature: true,
          tools_with_thinking_native: false,
          tools_with_thinking_route: nil
        )
      )
    end

    with_stubbed_class("SpecDoctorQualifiedSharedModelAgent", agent_class) do
      register_as :spec_doctor_qualified_shared_model_agent
      model "spec-doctor-qualified-shared-model", provider: :anthropic
    end

    report = Smith::Doctor::Report.new
    described_class.run(report)

    expect(report.checks.find { |c| c.name == "models.ambiguity" }).to be_nil
    check = report.checks.find { |c| c.name == "models.coverage" }
    expect(check.status).to eq(:pass)
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

  it "skips block-form fallback models without resolving them" do
    with_stubbed_class("SpecDoctorDynamicFallbackAgent", agent_class) do
      register_as :spec_doctor_dynamic_fallback_agent
      model "claude-sonnet-4-6", provider: :anthropic
      fallback_models { |_context| raise "fallback block resolved by the doctor" }
    end

    report = Smith::Doctor::Report.new
    described_class.run(report)

    check = report.checks.find { |c| c.name == "models.coverage" }
    expect(check.status).to eq(:pass)
  end
end
