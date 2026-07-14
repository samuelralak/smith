# frozen_string_literal: true

RSpec.describe Smith::PersistenceAdapters::RedisStore do
  it "does not recreate missing state from a nonzero expected version" do
    client = Class.new do
      def without_reconnect = yield
      def watch(_key) = yield
      def get(_key) = nil

      def multi
        raise "missing-version rejection must happen before MULTI"
      end
    end.new
    adapter = described_class.new(redis: client)

    expect do
      adapter.store_versioned(
        "missing",
        JSON.generate(persistence_version: 3),
        expected_version: 2
      )
    end.to raise_error(Smith::PersistenceVersionConflict) { |error|
      expect(error.expected).to eq(2)
      expect(error.actual).to eq(:missing)
    }
  end

  it "atomically replaces only the exact current payload" do
    client = exact_write_client("prepared")
    adapter = described_class.new(redis: client, identity: "redis:workflows")

    result = nil
    expect do
      result = adapter.replace_exact("run", "dispatching", expected_payload: "prepared", ttl: nil)
    end.to change { client.value }.from("prepared").to("dispatching")
    expect(result).to eq("dispatching")
    expect(adapter.persistence_identity).to eq("redis:workflows")
    expect(client.without_reconnect_calls).to eq(1)
  end

  it "does not mistake a command client for a callable factory" do
    client = exact_write_client("prepared")
    adapter = described_class.new(redis: client, identity: "redis:workflows")

    expect do
      adapter.replace_exact("run", "dispatching", expected_payload: "prepared", ttl: nil)
    end.to change { client.value }.to("dispatching")
    expect(client.command_calls).to be_empty
  end

  it "resolves a callable client source once under concurrent first access" do
    client = exact_write_client("prepared")
    calls = 0
    calls_mutex = Mutex.new
    adapter = described_class.new(
      redis: lambda do
        calls_mutex.synchronize { calls += 1 }
        sleep 0.01
        client
      end,
      identity: "redis:workflows"
    )

    results = Array.new(12) { Thread.new { adapter.fetch("run") } }.map(&:value)

    expect(results).to eq(Array.new(12, "prepared"))
    expect(calls).to eq(1)
  end

  it "rejects a stale exact payload before enqueueing a Redis write" do
    client = exact_write_client("mutated")
    adapter = described_class.new(redis: client, identity: "redis:workflows")

    expect do
      adapter.replace_exact("run", "dispatching", expected_payload: "prepared", ttl: nil)
    end.to raise_error(Smith::PersistencePayloadConflict)
    expect(client.value).to eq("mutated")
  end

  it "rejects a concurrent WATCH conflict" do
    client = exact_write_client("prepared", conflict: true)
    adapter = described_class.new(redis: client, identity: "redis:workflows")

    expect do
      adapter.replace_exact("run", "dispatching", expected_payload: "prepared", ttl: nil)
    end.to raise_error(Smith::PersistencePayloadConflict)
  end

  it "does not replay an exact replacement after an ambiguous Redis failure" do
    client = ambiguous_client
    adapter = described_class.new(redis: client, identity: "redis:workflows")

    expect do
      adapter.replace_exact("run", "dispatching", expected_payload: "prepared", ttl: nil)
    end.to raise_error(Smith::PersistenceIOError) { |error|
      expect(error.operation).to eq(:replace_exact)
      expect(error.cause).to be_a(Errno::EPIPE)
    }
    expect(client.watch_calls).to eq(1)
    expect(client.without_reconnect_calls).to eq(1)
  end

  it "does not replay a versioned write after an ambiguous Redis failure" do
    client = ambiguous_client
    adapter = described_class.new(redis: client)

    expect do
      adapter.store_versioned("run", JSON.generate(persistence_version: 1), expected_version: 0, ttl: nil)
    end.to raise_error(Smith::PersistenceIOError) { |error|
      expect(error.operation).to eq(:store_versioned)
    }
    expect(client.watch_calls).to eq(1)
    expect(client.without_reconnect_calls).to eq(1)
  end

  it "fails before WATCH when the client cannot disable reconnection" do
    client = exact_write_client("prepared")
    client.singleton_class.undef_method(:without_reconnect)
    adapter = described_class.new(redis: client, identity: "redis:workflows")

    expect do
      adapter.replace_exact("run", "dispatching", expected_payload: "prepared", ttl: nil)
    end.to raise_error(ArgumentError, /without_reconnect or disable_reconnection/)
    expect(client.watch_calls).to eq(0)
  end

  def ambiguous_client
    Class.new do
      attr_reader :watch_calls, :without_reconnect_calls

      def initialize
        @watch_calls = 0
        @without_reconnect_calls = 0
      end

      def get(*) = nil
      def set(*) = nil
      def del(*) = nil

      def without_reconnect
        @without_reconnect_calls += 1
        yield
      end

      def watch(*)
        @watch_calls += 1
        raise Errno::EPIPE
      end
    end.new
  end

  def exact_write_client(value, conflict: false)
    RedisExactWriteClient.new(value, conflict: conflict)
  end
end
