# frozen_string_literal: true

require "dry-struct"
require "securerandom"

module Smith
  class Event < Dry::Struct
    attribute(:execution_id, Types::String.default { SecureRandom.uuid })
    attribute(:trace_id, Types::String.default { SecureRandom.uuid })
  end
end
