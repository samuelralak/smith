# frozen_string_literal: true

# Pins the seed_validation contract: persisted state carries a digest
# of the seed_messages produced at construction time; restore can
# detect when the seed builder has changed in code since the workflow
# was persisted (drift). The host opts in to :strict (raise) or :warn
# (log); default :off skips validation because many seed builders are
# non-deterministic (timestamps, request IDs, etc.) and would surface
# false drift on every restore.

RSpec.describe "Smith::Workflow seed_messages drift validation" do
  let(:base_payload) do
    {
      class: "SpecSeedWorkflow",
      state: :idle,
      persistence_key: "workflow:seed",
      context: { topic: "history" },
      budget_consumed: {},
      step_count: 0,
      created_at: Time.now.utc.iso8601,
      updated_at: Time.now.utc.iso8601,
      session_messages: [{ role: :system, content: "Original system prompt" }],
      total_cost: 0.0,
      total_tokens: 0,
      tool_results: [],
      outcome: nil,
      usage_entries: [],
      last_output: nil,
      last_failed_step: nil,
      persistence_version: 1,
      schema_version: 1,
      seed_digest: nil # filled in per-test below
    }
  end

  def workflow_class_with_seed(validation: :off, &builder)
    Class.new(Smith::Workflow) do
      initial_state :idle
      state :done
      transition :finish, from: :idle, to: :done
      seed_validation(validation) if validation
      seed_messages(&builder)
    end
  end

  it "defaults seed_validation to :off" do
    klass = Class.new(Smith::Workflow) do
      initial_state :idle
      state :done
      transition :finish, from: :idle, to: :done
    end

    expect(klass.seed_validation).to eq(:off)
  end

  it "to_state carries seed_digest when a seed_messages builder is defined" do
    klass = workflow_class_with_seed do
      { role: :system, content: "static prompt" }
    end

    workflow = klass.new
    expect(workflow.to_state[:seed_digest]).to be_a(String)
    expect(workflow.to_state[:seed_digest].length).to eq(64) # SHA256 hex
  end

  it "to_state[:seed_digest] is nil when no seed_messages builder is defined" do
    klass = Class.new(Smith::Workflow) do
      initial_state :idle
      state :done
      transition :finish, from: :idle, to: :done
    end

    workflow = klass.new
    expect(workflow.to_state[:seed_digest]).to be_nil
  end

  it "to_state[:seed_digest] is nil when the seed_messages builder returns nil" do
    klass = workflow_class_with_seed do
      nil
    end

    workflow = klass.new
    expect(workflow.to_state[:seed_digest]).to be_nil
    expect(workflow.instance_variable_get(:@session_messages)).to eq([])
  end

  it "to_state[:seed_digest] is nil when the seed_messages builder returns an empty array" do
    klass = workflow_class_with_seed do
      []
    end

    workflow = klass.new
    expect(workflow.to_state[:seed_digest]).to be_nil
    expect(workflow.instance_variable_get(:@session_messages)).to eq([])
  end

  it "raises Smith::WorkflowError with a clear message when seed content is not valid UTF-8" do
    klass = workflow_class_with_seed do
      { role: :system, content: "binary \xFF byte".dup.force_encoding(Encoding::ASCII_8BIT) }
    end

    expect { klass.new }.to raise_error(Smith::WorkflowError, /seed_messages content must be valid UTF-8/)
  end

  it "produces a stable digest for an identical builder + identical context" do
    klass_one = workflow_class_with_seed do |ctx|
      { role: :system, content: "static prompt for #{ctx[:topic]}" }
    end
    klass_two = workflow_class_with_seed do |ctx|
      { role: :system, content: "static prompt for #{ctx[:topic]}" }
    end

    digest_one = klass_one.new(context: { topic: "history" }).to_state[:seed_digest]
    digest_two = klass_two.new(context: { topic: "history" }).to_state[:seed_digest]
    expect(digest_one).to eq(digest_two)
  end

  it "produces a different digest when the seed builder emits different content" do
    static = workflow_class_with_seed do
      { role: :system, content: "static prompt" }
    end
    changed = workflow_class_with_seed do
      { role: :system, content: "CHANGED prompt" }
    end

    expect(static.new.to_state[:seed_digest]).not_to eq(changed.new.to_state[:seed_digest])
  end

  describe ":off mode (default)" do
    it "does NOT raise on drift" do
      changed_klass = workflow_class_with_seed(validation: :off) do
        { role: :system, content: "CURRENT prompt" }
      end

      original_digest = Digest::SHA256.hexdigest(JSON.generate([{ role: :system, content: "ORIGINAL prompt" }]))
      payload = base_payload.merge(seed_digest: original_digest)

      expect { changed_klass.from_state(payload) }.not_to raise_error
    end

    it "does NOT log on drift" do
      logger = instance_double("Logger")
      allow(logger).to receive(:warn)
      original_logger = Smith.config.logger
      Smith.config.logger = logger

      changed_klass = workflow_class_with_seed(validation: :off) do
        { role: :system, content: "CURRENT prompt" }
      end
      original_digest = Digest::SHA256.hexdigest(JSON.generate([{ role: :system, content: "ORIGINAL prompt" }]))
      payload = base_payload.merge(seed_digest: original_digest)

      changed_klass.from_state(payload)
      expect(logger).not_to have_received(:warn)
    ensure
      Smith.config.logger = original_logger
    end
  end

  describe ":strict mode" do
    it "raises Smith::SeedMismatch when the seed builder produces a different digest" do
      changed_klass = workflow_class_with_seed(validation: :strict) do
        { role: :system, content: "CURRENT prompt" }
      end
      original_digest = Digest::SHA256.hexdigest(JSON.generate([{ role: :system, content: "ORIGINAL prompt" }]))
      payload = base_payload.merge(seed_digest: original_digest)

      expect { changed_klass.from_state(payload) }.to raise_error(Smith::SeedMismatch) do |err|
        expect(err.stored_digest).to eq(original_digest)
        expect(err.current_digest).to be_a(String)
        expect(err.current_digest).not_to eq(original_digest)
      end
    end

    it "does NOT raise when the seed builder produces the same digest" do
      seed_content = { role: :system, content: "static prompt" }
      digest = Digest::SHA256.hexdigest(JSON.generate([seed_content]))

      stable_klass = workflow_class_with_seed(validation: :strict) do
        seed_content
      end
      payload = base_payload.merge(seed_digest: digest)

      expect { stable_klass.from_state(payload) }.not_to raise_error
    end

    it "does NOT raise on legacy payloads (no seed_digest key)" do
      changed_klass = workflow_class_with_seed(validation: :strict) do
        { role: :system, content: "anything" }
      end

      legacy_payload = base_payload.dup
      legacy_payload.delete(:seed_digest)
      expect { changed_klass.from_state(legacy_payload) }.not_to raise_error
    end

    it "does NOT raise on payloads with explicit nil seed_digest" do
      changed_klass = workflow_class_with_seed(validation: :strict) do
        { role: :system, content: "anything" }
      end

      payload = base_payload.merge(seed_digest: nil)
      expect { changed_klass.from_state(payload) }.not_to raise_error
    end
  end

  describe ":warn mode" do
    it "logs a drift warning but does NOT raise" do
      logger = instance_double("Logger")
      allow(logger).to receive(:warn)
      original_logger = Smith.config.logger
      Smith.config.logger = logger

      changed_klass = workflow_class_with_seed(validation: :warn) do
        { role: :system, content: "CURRENT prompt" }
      end
      original_digest = Digest::SHA256.hexdigest(JSON.generate([{ role: :system, content: "ORIGINAL prompt" }]))
      payload = base_payload.merge(seed_digest: original_digest)

      expect { changed_klass.from_state(payload) }.not_to raise_error
      expect(logger).to have_received(:warn).with(/seed_messages drift/)
    ensure
      Smith.config.logger = original_logger
    end

    it "stays silent when there is no drift" do
      logger = instance_double("Logger")
      allow(logger).to receive(:warn)
      original_logger = Smith.config.logger
      Smith.config.logger = logger

      seed_content = { role: :system, content: "static prompt" }
      digest = Digest::SHA256.hexdigest(JSON.generate([seed_content]))
      stable_klass = workflow_class_with_seed(validation: :warn) do
        seed_content
      end
      payload = base_payload.merge(seed_digest: digest)

      stable_klass.from_state(payload)
      expect(logger).not_to have_received(:warn)
    ensure
      Smith.config.logger = original_logger
    end
  end

  it "uses the RESTORED context when re-evaluating the seed builder" do
    klass = workflow_class_with_seed(validation: :strict) do |ctx|
      { role: :system, content: "topic is #{ctx[:topic]}" }
    end

    original = klass.new(context: { topic: "history" })
    persisted = original.to_state

    expect { klass.from_state(persisted) }.not_to raise_error

    altered = persisted.merge(context: { topic: "biology" })
    expect { klass.from_state(altered) }.to raise_error(Smith::SeedMismatch)
  end

  it "round-trips seed_digest through JSON.generate / JSON.parse" do
    klass = workflow_class_with_seed do
      { role: :system, content: "static prompt" }
    end

    workflow = klass.new
    payload = JSON.parse(JSON.generate(workflow.to_state))
    restored = klass.from_state(payload)
    expect(restored.to_state[:seed_digest]).to eq(workflow.to_state[:seed_digest])
  end

  it "propagates seed_validation mode through class inheritance" do
    parent = workflow_class_with_seed(validation: :strict) do
      { role: :system, content: "static prompt" }
    end
    child = Class.new(parent)

    expect(child.seed_validation).to eq(:strict)
  end

  describe "DSL validation" do
    it "rejects unknown seed_validation modes" do
      expect {
        Class.new(Smith::Workflow) do
          seed_validation :loose
        end
      }.to raise_error(ArgumentError, /must be :strict, :warn, or :off/)
    end
  end
end
