# frozen_string_literal: true

require_relative "../scope"

module Smith
  module Evals
    # Experimental. Evals' settings (slice-1a design, 4.1), reached through
    # Smith::Evals.configure and Smith::Evals.config. Each run takes
    # `frozen_copy` when it starts and reads only that, so a later configure
    # (in a test, say) never reaches a running run.
    #
    # store: the eval store (slice 1a.3 gives the default file store).
    # dataset_root: where a suite's `dataset "name"` folders are found; nil
    # is the current directory. dataset_source: ->(name, scope:) for suites
    # built from data (slice 1b). host_code_version: the host's own code
    # version, recorded in every header. cost_unit: the pricing catalog's
    # unit. default_scope: the tenant scope when a call names none.
    # recording: step record bounds, each capped at its ceiling (5.4).
    class Configuration
      RECORDING_DEFAULTS = { content: true, max_steps: 256, max_message_bytes: 32_768, max_tool_bytes: 4_096,
                             max_step_bytes: 262_144, max_trial_bytes: 4_194_304 }.freeze
      RECORDING_CEILINGS = { max_steps: 4_096, max_message_bytes: 1_048_576, max_tool_bytes: 1_048_576,
                             max_step_bytes: 4_194_304, max_trial_bytes: 8_388_608 }.freeze
      MAX_HOST_CODE_VERSION = 128

      attr_accessor :store
      attr_reader :dataset_root, :dataset_source, :host_code_version, :cost_unit, :default_scope, :recording

      def initialize
        @store = nil
        @dataset_root = nil
        @dataset_source = nil
        @host_code_version = nil
        @cost_unit = "USD"
        @default_scope = Smith::Scope.build({})
        @recording = RECORDING_DEFAULTS
      end

      def dataset_root=(value)
        raise ArgumentError, "dataset_root is nil or a folder path" unless value.nil? || path?(value)

        @dataset_root = value.nil? ? nil : value.to_s.dup.freeze
      end

      def dataset_source=(value)
        unless value.nil? || value.respond_to?(:call)
          raise ArgumentError, "dataset_source is nil or responds to call(name, scope:)"
        end

        @dataset_source = value
      end

      def host_code_version=(value)
        unless value.nil? || (text?(value) && value.length <= MAX_HOST_CODE_VERSION)
          raise ArgumentError, "host_code_version is nil or a String of at most #{MAX_HOST_CODE_VERSION} characters"
        end

        @host_code_version = value&.dup&.freeze
      end

      def cost_unit=(value)
        raise ArgumentError, "cost_unit is a String such as \"USD\"" unless text?(value) && value.length <= 16

        @cost_unit = value.dup.freeze
      end

      def default_scope=(value)
        @default_scope = Smith::Scope.build(value)
      end

      # Bounds given in part keep the defaults for the rest.
      def recording=(value)
        raise ArgumentError, "recording is a Hash of settings" unless value.is_a?(Hash)

        @recording = value.each_with_object(@recording.dup) do |(key, setting), bounds|
          name = key.to_sym
          bounds[name] = recording_setting(name, setting)
        end.freeze
      end

      # A frozen copy for one run.
      def frozen_copy
        dup.freeze
      end

      private

      def recording_setting(name, setting)
        if name == :content
          raise ArgumentError, "recording content is true or false" unless [true, false].include?(setting)

          return setting
        end
        ceiling = RECORDING_CEILINGS.fetch(name) { raise ArgumentError, "unknown recording setting #{name}" }
        return setting if setting.is_a?(Integer) && setting.between?(1, ceiling)

        raise ArgumentError, "recording #{name} is an Integer from 1 to #{ceiling}"
      end

      def text?(value)
        value.is_a?(String) && !value.empty? && value.valid_encoding?
      end

      def path?(value)
        (value.is_a?(String) || value.respond_to?(:to_path)) && !value.to_s.empty?
      end
    end

    CONFIG_LOCK = Mutex.new
    private_constant :CONFIG_LOCK

    class << self
      # Yields the configuration to change it; returns it.
      def configure
        yield config
        config
      end

      def config
        CONFIG_LOCK.synchronize { @config ||= Configuration.new }
      end
    end
  end
end
