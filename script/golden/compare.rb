# frozen_string_literal: true

module CoreInvisibility
  # How two golden files differ, a line a part: the header's parts by the
  # keys that differ, then each scenario by the sinks that differ, or the
  # file it is only in. What a regenerated golden's report starts from.
  module Compare
    HEADER = %w[smith environment process host_surface].freeze

    module_function

    def lines(first, second)
      scenarios = first["scenarios"].keys | second["scenarios"].keys
      HEADER.map { "#{_1}: #{differing(first[_1], second[_1])}" } +
        scenarios.map { "#{_1}: #{scenario(first["scenarios"][_1], second["scenarios"][_1])}" }
    end

    def scenario(first, second)
      return "only in the second" unless first
      return "only in the first" unless second

      differing(first, second)
    end

    def differing(first, second)
      first = first.to_h
      second = second.to_h
      keys = (first.keys | second.keys).reject { first[_1] == second[_1] }
      keys.empty? ? "same" : keys.join(", ")
    end
  end
end
