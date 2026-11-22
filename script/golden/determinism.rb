# frozen_string_literal: true

require "securerandom"
require "time"

module CoreInvisibility
  # Reproducible ids and time for the harness: SecureRandom.uuid and .hex
  # count from 1 in each scenario, every other SecureRandom method draws
  # counted bytes (they all go through gen_random), and Time.now stands
  # still unless a scenario moves it (a durable wait's deadline). The draw
  # count is part of the golden document, so an extra draw of any kind inside
  # the subject shows.
  module Determinism
    BASE_TIME = Time.utc(2026, 1, 1).to_i
    UUID = "00000000-0000-4000-8000-%012x"
    private_constant :UUID

    @lock = Mutex.new
    @draws = 0
    @offset = 0

    # Prepended over SecureRandom's own methods.
    module Counter
      def uuid = Determinism.uuid
      def hex(bytes = nil) = Determinism.hex(bytes)
      def gen_random(count) = Determinism.bytes(count)
    end

    # Prepended over Time.now.
    module StillClock
      def now(**) = Determinism.now
    end

    class << self
      def install!
        SecureRandom.singleton_class.prepend(Counter)
        Time.singleton_class.prepend(StillClock)
      end

      def reset! = @lock.synchronize { (@draws = 0) && (@offset = 0) }
      def draws = @lock.synchronize { @draws }
      def uuid = format(UUID, draw)
      def hex(bytes) = draw.to_s(16).rjust(2 * (bytes || 16), "0")
      def bytes(count) = (seed = draw) && Array.new(count) { ((seed * 131) + (_1 * 17)) & 0xff }.pack("C*")
      def now = Time.at(BASE_TIME + @offset).utc
      def advance(seconds) = @lock.synchronize { @offset += seconds }

      private

      def draw = @lock.synchronize { @draws += 1 }
    end
  end
end
