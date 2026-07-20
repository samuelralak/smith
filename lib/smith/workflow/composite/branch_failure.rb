# frozen_string_literal: true

require_relative "../../errors"
require_relative "error"

module Smith
  class Workflow
    module Composite
      class BranchFailure < WorkflowError
        DETAIL_KEYS = {
          "branch_key" => :branch_key,
          "error_class" => :error_class,
          "error_family" => :error_family,
          "retryable" => :retryable,
          "kind" => :kind
        }.freeze
        DETAIL_NAMES = DETAIL_KEYS.values.freeze
        private_constant :DETAIL_KEYS, :DETAIL_NAMES

        attr_reader :branch_key, :error_class, :error_family, :retryable, :kind, :details

        def self.from_details(details)
          values = normalize_details(details)
          error = Error.new(
            class_name: values.fetch(:error_class),
            family: values.fetch(:error_family),
            retryable: values.fetch(:retryable),
            kind: values.fetch(:kind)
          )
          new(branch_key: values.fetch(:branch_key), error:)
        end

        def self.normalize_details(details)
          raise ArgumentError, "composite branch failure details must be a Hash" unless details.is_a?(Hash)

          normalized = {}
          Hash.instance_method(:each_pair).bind_call(details) do |key, value|
            name = normalize_detail_key(key)
            if normalized.key?(name)
              raise ArgumentError, "composite branch failure details contain a duplicate attribute"
            end

            normalized[name] = value
          end
          missing = DETAIL_NAMES - normalized.keys
          raise ArgumentError, "composite branch failure details are missing required attributes" if missing.any?

          normalized
        end

        def self.normalize_detail_key(key)
          name = key.is_a?(Symbol) ? key : DETAIL_KEYS.fetch(key, key)
          return name if DETAIL_NAMES.include?(name)

          raise ArgumentError, "composite branch failure details contain an unknown attribute"
        end
        private_class_method :normalize_details
        private_class_method :normalize_detail_key

        def initialize(branch_key:, error:)
          validate_arguments!(branch_key, error)
          @branch_key = branch_key.dup.freeze
          @error_class = error.class_name.dup.freeze
          @error_family = error.family.dup.freeze
          @retryable = error.retryable
          @kind = error.kind&.dup&.freeze
          @details = failure_details
          super("composite branch #{branch_key.inspect} failed")
        end

        private

        def validate_arguments!(branch_key, error)
          valid_key = branch_key.is_a?(String) && branch_key.length.between?(1, 256)
          raise ArgumentError, "composite branch failure key must be a bounded non-empty String" unless valid_key
          raise ArgumentError, "composite branch failure requires typed error evidence" unless error.is_a?(Error)
        end

        def failure_details
          {
            branch_key: @branch_key,
            error_class: @error_class,
            error_family: @error_family,
            retryable: @retryable,
            kind: @kind
          }.freeze
        end
      end
    end
  end
end
