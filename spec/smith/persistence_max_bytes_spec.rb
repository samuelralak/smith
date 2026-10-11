# frozen_string_literal: true

# Smith.config.persistence_max_bytes: a stored workflow state's bound,
# refused before anything is written.
RSpec.describe "Smith.config.persistence_max_bytes" do
  let(:workflow_class) { require_const("Smith::Workflow") }
  let(:adapter) { Smith::PersistenceAdapters::Memory.new }

  around do |example|
    saved = Smith.config.persistence_max_bytes
    example.run
  ensure
    Smith.config.persistence_max_bytes = saved
  end

  def writing(name, bytes)
    with_stubbed_class(name, workflow_class) do
      initial_state :idle
      state :failed
      transition :write, from: :idle, to: :done do
        compute { |step| step.write_context(:notes, "n" * bytes) }
      end
    end
  end

  it "is nil or a positive Integer" do
    [0, -1, "1024", 1.5].each do |value|
      expect { Smith.config.persistence_max_bytes = value }.to raise_error(ArgumentError, /persistence_max_bytes/)
    end
    expect { Smith.config.persistence_max_bytes = 2048 }.not_to raise_error
    expect { Smith.config.persistence_max_bytes = nil }.not_to raise_error
  end

  it "refuses a state past it before writing, and the stored state stays as it was" do
    Smith.config.persistence_max_bytes = 4096
    klass = writing("SpecMaxBytesWorkflow", 8192)
    run = klass.new(context: {})

    expect { run.run_persisted!("run-big", adapter:) }.to raise_error(Smith::PersistedStateTooLarge) { |error|
      expect([error.key, error.limit, error.bytes > 8192]).to eq(["run-big", 4096, true])
    }
    stored = klass.restore("run-big", adapter:)
    expect([stored.state, stored.to_state[:context]]).to eq([:idle, {}])

    Smith.config.persistence_max_bytes = 64 * 1024
    expect(klass.restore("run-big", adapter:).run_persisted!("run-big", adapter:).state).to eq(:done)
  end
end
