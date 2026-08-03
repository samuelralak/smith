# frozen_string_literal: true

require "dry-struct"
require "securerandom"

require_relative "attribution"

module Smith
  class Event < Dry::Struct
    # Both ids default to the ambient Smith::Attribution execution key, so
    # events emitted under one persisted run (or one host-seeded
    # Attribution scope) share one identity a host can group by. Outside
    # any scope, each event falls back to its own random UUID, so
    # non-persisted, unseeded runs have no shared event identity. Callers
    # may always pass explicit values.
    attribute(:execution_id, Types::String.default { Smith::Attribution.ambient.execution_key || SecureRandom.uuid })
    attribute(:trace_id, Types::String.default { Smith::Attribution.ambient.execution_key || SecureRandom.uuid })
  end
end
