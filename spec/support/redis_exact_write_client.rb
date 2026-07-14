# frozen_string_literal: true

class RedisExactWriteClient
  attr_reader :value, :without_reconnect_calls, :watch_calls, :command_calls

  def initialize(value, conflict: false)
    @value = value
    @conflict = conflict
    @without_reconnect_calls = 0
    @watch_calls = 0
    @command_calls = []
  end

  def call(*command) = @command_calls << command
  def del(*) = nil

  def without_reconnect
    @without_reconnect_calls += 1
    yield
  end

  def watch(_key)
    @watch_calls += 1
    yield
  end

  def get(_key) = value
  def unwatch = nil

  def multi
    return if @conflict

    yield self
    ["OK"]
  end

  def set(_key, payload, **) = @value = payload
end
