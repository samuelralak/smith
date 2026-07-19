# frozen_string_literal: true

module Smith
  class ExponentialBackoff
    MAX_SLEEP_INTERVAL_SECONDS = 2_147_483_647.0
    MAX_RANDOM_FACTOR = 1.0.prev_float

    attr_reader :attempts, :base_delay, :max_delay, :jitter

    def initialize(attempts:, base_delay:, max_delay:, jitter:, delay_label: "base_delay")
      @attempt_limit = Smith.config.retry_attempt_limit
      @attempts = validate_attempts!(attempts)
      @base_delay = normalize_delay!(base_delay, delay_label)
      @max_delay = normalize_optional_delay!(max_delay, "max_delay")
      @jitter = normalize_delay!(jitter, "jitter")
      validate_finite_schedule!
      freeze
    end

    def delay(failed_attempt, random: Kernel.method(:rand))
      validate_failed_attempt!(failed_attempt)

      base = exponential_delay(failed_attempt - 1)
      return base if jitter.zero? || max_delay == base

      add_jitter(base, random.call)
    end

    private

    def validate_attempts!(value)
      raise ArgumentError, "attempts must be a positive integer" unless value.is_a?(Integer) && value.positive?
      raise ArgumentError, "attempts must not exceed #{@attempt_limit}" if value > @attempt_limit

      value
    end

    def normalize_optional_delay!(value, label)
      return if value.nil?

      normalize_delay!(value, label)
    end

    def normalize_delay!(value, label)
      numeric = Float(value)
      return numeric if numeric.finite? && numeric >= 0.0

      raise ArgumentError, "#{label} must be finite and non-negative"
    rescue TypeError, ArgumentError, RangeError
      raise ArgumentError, "#{label} must be finite and non-negative"
    end

    def validate_finite_schedule!
      return if attempts == 1

      largest_delay = maximum_delay(attempts - 2)
      return if largest_delay <= MAX_SLEEP_INTERVAL_SECONDS

      raise ArgumentError, "retry delay exceeds supported sleep interval #{MAX_SLEEP_INTERVAL_SECONDS.to_i} seconds"
    end

    def validate_failed_attempt!(failed_attempt)
      return if failed_attempt.is_a?(Integer) && failed_attempt.positive? && failed_attempt < attempts

      raise ArgumentError, "failed_attempt must identify a retryable attempt"
    end

    def exponential_delay(exponent)
      return 0.0 if base_delay.zero? || max_delay&.zero?
      return uncapped_exponential_delay(exponent) unless max_delay

      capped_exponential_delay(exponent)
    end

    def capped_exponential_delay(exponent)
      base_fraction, base_exponent = Math.frexp(base_delay)
      cap_fraction, cap_exponent = Math.frexp(max_delay)
      scaled_exponent = base_exponent + exponent

      return max_delay if scaled_exponent > cap_exponent
      return max_delay if scaled_exponent == cap_exponent && base_fraction >= cap_fraction

      [Math.ldexp(base_delay, exponent), max_delay].min
    end

    def uncapped_exponential_delay(exponent)
      _fraction, base_exponent = Math.frexp(base_delay)
      if base_exponent + exponent > Float::MAX_EXP
        raise ArgumentError, "retry schedule exceeds the finite numeric range"
      end

      Math.ldexp(base_delay, exponent).tap do |value|
        raise ArgumentError, "retry schedule exceeds the finite numeric range" unless value.finite?
      end
    end

    def add_jitter(base, random_value)
      factor = normalize_random_factor!(random_value)
      sampled = jitter * factor
      return max_delay if max_delay && sampled >= max_delay - base

      base + sampled
    end

    def normalize_random_factor!(value)
      factor = Float(value)
      unless factor.finite? && factor >= 0.0 && factor < 1.0
        raise ArgumentError, "random value must be finite and within 0.0...1.0"
      end

      factor
    rescue TypeError, ArgumentError, RangeError
      raise ArgumentError, "random value must be finite and within 0.0...1.0"
    end

    def maximum_delay(exponent)
      base = exponential_delay(exponent)
      return base if jitter.zero? || max_delay == base

      sampled = jitter * MAX_RANDOM_FACTOR
      return max_delay if max_delay && sampled >= max_delay - base

      (base + sampled).tap do |value|
        raise ArgumentError, "retry schedule exceeds the finite numeric range" unless value.finite?
      end
    end
  end
end
