# frozen_string_literal: true

require "smith/doctor"

RSpec.describe Smith::Doctor::Checks::Persistence do
  describe "schema_presence" do
    it "skips when ActiveRecord is not defined" do
      report = Smith::Doctor::Report.new
      # In test env, ActiveRecord is not loaded
      described_class.check_schema_presence(report)

      check = report.checks.find { |c| c.name == "persistence.schema_presence" }
      expect(check.status).to eq(:skip)
    end
  end

  describe "model_registry_mode" do
    it "reports bundled fallback when config is nil" do
      original = Smith.config.ruby_llm_model_registry
      Smith.configure { |c| c.ruby_llm_model_registry = nil }

      report = Smith::Doctor::Report.new
      described_class.check_model_registry_mode(report)

      check = report.checks.find { |c| c.name == "persistence.model_registry_mode" }
      expect(check.status).to eq(:pass)
      expect(check.message).to include("bundled fallback")
    ensure
      Smith.configure { |c| c.ruby_llm_model_registry = original }
    end

    it "passes with bundled messaging when explicitly :bundled" do
      original = Smith.config.ruby_llm_model_registry
      Smith.configure { |c| c.ruby_llm_model_registry = :bundled }

      report = Smith::Doctor::Report.new
      described_class.check_model_registry_mode(report)

      check = report.checks.find { |c| c.name == "persistence.model_registry_mode" }
      expect(check.status).to eq(:pass)
      expect(check.message).to include("bundled (explicit)")
    ensure
      Smith.configure { |c| c.ruby_llm_model_registry = original }
    end

    it "fails when :database is set but registry class is not resolvable" do
      original = Smith.config.ruby_llm_model_registry
      Smith.configure { |c| c.ruby_llm_model_registry = :database }

      report = Smith::Doctor::Report.new
      described_class.check_model_registry_mode(report)

      check = report.checks.find { |c| c.name == "persistence.model_registry_mode" }
      expect(check.status).to eq(:fail)
    ensure
      Smith.configure { |c| c.ruby_llm_model_registry = original }
    end

    it "fails when :database registry class exists but is not ActiveRecord-backed" do
      original = Smith.config.ruby_llm_model_registry
      Smith.configure { |c| c.ruby_llm_model_registry = :database }

      # Stub a resolvable but non-AR class
      stub_const("FakeModelRegistry", Class.new)
      allow(RubyLLM.config).to receive(:model_registry_class).and_return("FakeModelRegistry")

      report = Smith::Doctor::Report.new
      described_class.check_model_registry_mode(report)

      check = report.checks.find { |c| c.name == "persistence.model_registry_mode" }
      expect(check.status).to eq(:fail)
      expect(check.message).to include("not ActiveRecord-backed")
    ensure
      Smith.configure { |c| c.ruby_llm_model_registry = original }
    end

    it "does not accept bundled fallback as proof in strict :database mode" do
      original = Smith.config.ruby_llm_model_registry
      Smith.configure { |c| c.ruby_llm_model_registry = :database }

      # RubyLLM.models.all would return 1184 bundled models
      # but strict :database mode must verify the DB class directly, not the facade
      report = Smith::Doctor::Report.new
      described_class.check_model_registry_mode(report)

      check = report.checks.find { |c| c.name == "persistence.model_registry_mode" }
      expect(check.status).to eq(:fail)
    ensure
      Smith.configure { |c| c.ruby_llm_model_registry = original }
    end

    it "passes when :database is set and the DB-backed registry class exists with records" do
      original = Smith.config.ruby_llm_model_registry
      Smith.configure { |c| c.ruby_llm_model_registry = :database }

      stub_const("ActiveRecord::Base", Class.new)
      stub_const("FakeModelRegistry", Class.new(ActiveRecord::Base))
      FakeModelRegistry.define_singleton_method(:table_exists?) { true }
      FakeModelRegistry.define_singleton_method(:table_name) { "ruby_llm_models" }
      FakeModelRegistry.define_singleton_method(:count) { 3 }

      allow(RubyLLM.config).to receive(:model_registry_class).and_return("FakeModelRegistry")

      report = Smith::Doctor::Report.new
      described_class.check_model_registry_mode(report)

      check = report.checks.find { |c| c.name == "persistence.model_registry_mode" }
      expect(check.status).to eq(:pass)
      expect(check.message).to include("operational")
      expect(check.message).to include("3")
    ensure
      Smith.configure { |c| c.ruby_llm_model_registry = original }
    end
  end

  describe "ruby_llm_persistence surface" do
    it "warns when RubyLLM persistence surface is not detected" do
      report = Smith::Doctor::Report.new
      described_class.check_ruby_llm_persistence(report)

      check = report.checks.find { |c| c.name == "persistence.ruby_llm_surface" }
      # In test env, RubyLLM::Chat is not AR-backed
      expect(check.status).to eq(:warn)
      expect(check.message).to include("not detected")
    end
  end
end
