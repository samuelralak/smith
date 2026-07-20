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
          "kind" => :kind,
          "tool_name" => :tool_name,
          "reason" => :reason
        }.freeze
        REQUIRED_DETAIL_NAMES = %i[branch_key error_class error_family retryable kind].freeze
        OPTIONAL_DETAIL_NAMES = %i[tool_name reason].freeze
        DETAIL_NAMES = (REQUIRED_DETAIL_NAMES + OPTIONAL_DETAIL_NAMES).freeze
        private_constant :DETAIL_KEYS, :REQUIRED_DETAIL_NAMES, :OPTIONAL_DETAIL_NAMES, :DETAIL_NAMES

        attr_reader :branch_key, :error_class, :error_family, :retryable, :kind, :tool_name, :reason, :details

        def self.from_details(details)
          values = normalize_details(details)
          error_attributes = {
            class_name: values.fetch(:error_class),
            family: values.fetch(:error_family),
            retryable: values.fetch(:retryable),
            kind: values.fetch(:kind)
          }
          OPTIONAL_DETAIL_NAMES.each do |name|
            error_attributes[name] = values[name] if values.key?(name)
          end
          error = Error.new(error_attributes)
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
          missing = REQUIRED_DETAIL_NAMES - normalized.keys
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
          copy_error_attributes(error)
          @details = failure_details
          super("composite branch #{branch_key.inspect} failed")
        end

        private

        def validate_arguments!(branch_key, error)
          valid_key = branch_key.is_a?(String) && branch_key.length.between?(1, 256)
          raise ArgumentError, "composite branch failure key must be a bounded non-empty String" unless valid_key
          raise ArgumentError, "composite branch failure requires typed error evidence" unless error.is_a?(Error)
        end

        def copy_error_attributes(error)
          @error_class = owned_string(error.class_name)
          @error_family = owned_string(error.family)
          @retryable = error.retryable
          @kind = owned_string(error.kind)
          @tool_name = owned_string(error.tool_name)
          @reason = owned_string(error.reason)
        end

        def owned_string(value)
          value&.dup&.freeze
        end

        def failure_details
          values = {
            branch_key: @branch_key,
            error_class: @error_class,
            error_family: @error_family,
            retryable: @retryable,
            kind: @kind
          }
          values[:tool_name] = @tool_name if @tool_name
          values[:reason] = @reason if @reason
          values.freeze
        end
      end
    end
  end
end
