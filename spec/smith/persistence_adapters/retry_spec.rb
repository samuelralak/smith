# frozen_string_literal: true

RSpec.describe Smith::PersistenceAdapters::Retry do
  # Use Errno::ECONNREFUSED as a stable transient error class (present
  # in any Ruby stdlib, no gem-specific imports needed).
  let(:transient) { [Errno::ECONNREFUSED] }
  let(:policy) { { attempts: 3, base_delay: 0, max_delay: 0 } }

  it "returns the block result on first-attempt success" do
    calls = 0
    result = described_class.with_retries(operation: :fetch, transient: transient, policy: policy) do
      calls += 1
      "ok"
    end
    expect(result).to eq("ok")
    expect(calls).to eq(1)
  end

  it "succeeds on retry after a transient failure" do
    calls = 0
    result = described_class.with_retries(operation: :store, transient: transient, policy: policy) do
      calls += 1
      raise Errno::ECONNREFUSED if calls < 2

      "recovered"
    end
    expect(result).to eq("recovered")
    expect(calls).to eq(2)
  end

  it "retries up to policy.attempts before raising PersistenceIOError" do
    calls = 0
    expect do
      described_class.with_retries(operation: :store, transient: transient, policy: policy) do
        calls += 1
        raise Errno::ECONNREFUSED, "boom"
      end
    end.to raise_error(Smith::PersistenceIOError) do |err|
      expect(err.operation).to eq(:store)
      expect(err.cause).to be_a(Errno::ECONNREFUSED)
    end
    expect(calls).to eq(3)
  end

  it "does NOT retry on non-transient errors" do
    calls = 0
    expect do
      described_class.with_retries(operation: :store, transient: transient, policy: policy) do
        calls += 1
        raise ArgumentError, "permanent"
      end
    end.to raise_error(ArgumentError)
    expect(calls).to eq(1)
  end

  it "respects each adapter's distinct transient-error list" do
    # An adapter passing only Redis errors should NOT retry on AR errors.
    calls = 0
    expect do
      described_class.with_retries(
        operation: :store,
        transient: [Errno::ECONNREFUSED],
        policy: policy
      ) do
        calls += 1
        raise Errno::EPIPE, "different transient"
      end
    end.to raise_error(Errno::EPIPE)
    expect(calls).to eq(1)
  end

  it "uses Smith.config.persistence_retry_policy by default" do
    Smith.config.persistence_retry_policy = { attempts: 2, base_delay: 0, max_delay: 0 }
    calls = 0
    expect do
      described_class.with_retries(operation: :store, transient: transient) do
        calls += 1
        raise Errno::ECONNREFUSED, "boom"
      end
    end.to raise_error(Smith::PersistenceIOError)
    expect(calls).to eq(2)
  ensure
    Smith.config.persistence_retry_policy = { attempts: 3, base_delay: 0.1, max_delay: 1.0 }
  end

  it "rejects invalid policies before calling the adapter operation" do
    called = false

    expect do
      described_class.with_retries(
        operation: :store,
        transient: transient,
        policy: { attempts: 1_000_000, base_delay: 0, max_delay: 0 }
      ) { called = true }
    end.to raise_error(ArgumentError, /must not exceed/)
    expect(called).to be(false)
  end

  it "rejects non-finite persistence delays" do
    expect do
      described_class.with_retries(
        operation: :store,
        transient: transient,
        policy: { attempts: 2, base_delay: Float::INFINITY, max_delay: nil }
      ) { "unused" }
    end.to raise_error(ArgumentError, /finite and non-negative/)
  end

  it "rejects unschedulable finite delays before calling the adapter operation" do
    called = false

    expect do
      described_class.with_retries(
        operation: :store,
        transient: transient,
        policy: { attempts: 2, base_delay: 3_000_000_000.0, max_delay: nil }
      ) { called = true }
    end.to raise_error(ArgumentError, /supported sleep interval/)
    expect(called).to be(false)
  end

  it "retries through an extreme base delay when the policy supplies a safe cap" do
    calls = 0
    allow(described_class).to receive(:sleep)

    result = described_class.with_retries(
      operation: :store,
      transient: transient,
      policy: { attempts: 2, base_delay: Float::MAX, max_delay: 0.25 }
    ) do
      calls += 1
      raise Errno::ECONNREFUSED if calls == 1

      :recovered
    end

    expect(result).to eq(:recovered)
    expect(calls).to eq(2)
    expect(described_class).to have_received(:sleep).with(0.25)
  end

  it "accepts the exact supported sleep boundary before adapter work" do
    calls = 0
    allow(described_class).to receive(:sleep)

    expect do
      described_class.with_retries(
        operation: :store,
        transient: transient,
        policy: {
          attempts: 2,
          base_delay: Smith::ExponentialBackoff::MAX_SLEEP_INTERVAL_SECONDS,
          max_delay: nil
        }
      ) do
        calls += 1
        raise Errno::ECONNREFUSED
      end
    end.to raise_error(Smith::PersistenceIOError)
    expect(calls).to eq(2)
    expect(described_class).to have_received(:sleep)
      .with(Smith::ExponentialBackoff::MAX_SLEEP_INTERVAL_SECONDS)
  end
end
