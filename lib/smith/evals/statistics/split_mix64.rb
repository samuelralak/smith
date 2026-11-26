# frozen_string_literal: true

module Smith
  module Evals
    module Statistics
      # SplitMix64, the one generator Smith's statistics draw from, written
      # out so every language draws the same numbers (design 7.2). Ruby's
      # Random is not used: its range draws are not promised to stay the same
      # across Ruby versions. Frozen with slice 1a.1.
      #
      # Each draw adds 0x9E3779B97F4A7C15 to a 64-bit state, mixes it and
      # returns 64 bits. `below(n)` draws by rejection, so every value below
      # n is equally likely. O(1) a draw (expected for `below`), O(1) space.
      # One instance is one stream; it is not shared between threads.
      class SplitMix64
        MASK = (1 << 64) - 1
        GAMMA = 0x9E3779B97F4A7C15
        MIX_A = 0xBF58476D1CE4E5B9
        MIX_B = 0x94D049BB133111EB
        SPAN = 1 << 64
        private_constant :MASK, :GAMMA, :MIX_A, :MIX_B, :SPAN

        # A seed as 16 hex digits, the form results record.
        def self.from_hex(hex)
          unless hex.is_a?(String) && hex.match?(/\A[0-9a-f]{16}\z/)
            raise ArgumentError, "a SplitMix64 seed in hex is 16 lowercase hex digits"
          end

          new(hex.to_i(16))
        end

        def initialize(seed)
          unless seed.is_a?(Integer) && seed.between?(0, MASK)
            raise ArgumentError, "a SplitMix64 seed is an Integer from 0 to 2**64 - 1"
          end

          @state = seed
        end

        # The state as 16 hex digits: `from_hex` of it draws on where this
        # one is, so a saved run continues its stream (slice 5a).
        def to_hex = format("%016x", @state)

        # The next 64-bit value, as an Integer.
        def next_u64
          @state = (@state + GAMMA) & MASK
          mixed = ((@state ^ (@state >> 30)) * MIX_A) & MASK
          mixed = ((mixed ^ (mixed >> 27)) * MIX_B) & MASK
          mixed ^ (mixed >> 31)
        end

        # An Integer in 0...n: draws at or above the largest multiple of n
        # below 2**64 are drawn again.
        def below(bound)
          unless bound.is_a?(Integer) && bound.between?(1, SPAN)
            raise ArgumentError, "SplitMix64#below takes an Integer from 1 to 2**64"
          end

          limit = SPAN - (SPAN % bound)
          loop do
            value = next_u64
            return value % bound if value < limit
          end
        end
      end
    end
  end
end
