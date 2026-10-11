# frozen_string_literal: true

require_relative "errors"
require_relative "diagnostic_text"

module Smith
  # A `map` or `call` step whose child runs did not all succeed, under
  # `on_item_failure: :fail`. Its failure family is `child_runs_failed`;
  # details name the transition, up to MAX_REFS failed refs and the counts,
  # and persist with the failed step.
  class ChildRunsFailed < WorkflowError
    DETAIL_NAMES = %i[transition failed_refs failed total].freeze
    DETAIL_KEYS = DETAIL_NAMES.to_h { |name| [name.to_s.freeze, name] }.freeze
    MAX_REFS = 20
    private_constant :DETAIL_NAMES, :DETAIL_KEYS

    attr_reader :transition, :failed_refs, :failed, :total

    def initialize(transition:, failed_refs:, total:, failed: failed_refs.length, message: nil)
      @transition = DiagnosticText.capture(transition.to_s, max_bytes: 256)
      @failed_refs = Array(failed_refs).first(MAX_REFS).freeze
      @failed = failed
      @total = total
      super(message || "#{failed} of #{total} child runs of #{@transition} failed (refs #{@failed_refs.join(", ")})")
    end

    def details = { transition:, failed_refs:, failed:, total: }.freeze

    def self.from_details(details, message: nil)
      raise ArgumentError, "child run failure details must be a Hash" unless details.is_a?(Hash)

      values = details.to_h { |key, value| [key.is_a?(Symbol) ? key : DETAIL_KEYS[key], value] }
      unless values.keys.sort == DETAIL_NAMES.sort && valid_counts?(values)
        raise ArgumentError, "child run failure details are invalid"
      end

      new(transition: values[:transition], failed_refs: values[:failed_refs], failed: values[:failed],
          total: values[:total], message:)
    end

    # Counts within bounds, and refs that are distinct indexes of the total,
    # as many as the failures up to MAX_REFS (so neither count is negative).
    def self.valid_counts?(values)
      refs, failed, total = values.values_at(:failed_refs, :failed, :total)
      return false unless values[:transition].is_a?(String) && [failed, total].all?(Integer)

      failed <= total && valid_refs?(refs, failed, total)
    end

    def self.valid_refs?(refs, failed, total)
      refs.is_a?(Array) && refs.all? { _1.is_a?(Integer) && _1.between?(0, total - 1) } &&
        refs.length == [failed, MAX_REFS].min && refs.uniq.length == refs.length
    end
    private_class_method :valid_counts?, :valid_refs?
  end
end
