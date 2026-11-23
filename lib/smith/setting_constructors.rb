# frozen_string_literal: true

module Smith
  # Constructors that check Smith.config's settings as they are set.
  module SettingConstructors
    module_function

    def positive_integer(name)
      lambda do |value|
        unless value.is_a?(Integer) && value.positive?
          raise ArgumentError, "Smith.config.#{name} must be a positive integer, got #{value.inspect}"
        end

        value
      end
    end

    def optional_positive_integer(name)
      lambda do |value|
        next value if value.nil? || (value.is_a?(Integer) && value.positive?)

        raise ArgumentError, "Smith.config.#{name} must be nil or a positive Integer, got #{value.inspect}"
      end
    end

    def bounded_positive_integer(name, maximum)
      lambda do |value|
        unless value.is_a?(Integer) && value.positive? && value <= maximum
          message = "Smith.config.#{name} must be a positive integer no greater than #{maximum}"
          raise ArgumentError, "#{message}, got #{value.inspect}"
        end

        value
      end
    end

    # A list of StandardError subclasses, frozen; nil is none. StandardError
    # itself would match every error, and an error outside it never reaches
    # a step's rescue.
    def error_classes(name)
      lambda do |value|
        classes = Array(value)
        unless classes.all? { _1.is_a?(Class) && _1 < StandardError }
          raise ArgumentError, "Smith.config.#{name} must list subclasses of StandardError, got #{value.inspect}"
        end

        classes.uniq.freeze
      end
    end

    # The fail-closed mode for run credentials (`provider_credentials`): true
    # or false, and never true while a credentialed run's RubyLLM context
    # keeps its instrumenter.
    def require_run_credentials
      lambda do |value|
        unless [true, false].include?(value)
          raise ArgumentError, "Smith.config.require_run_credentials must be true or false, got #{value.inspect}"
        end

        if value && Smith.config.run_credentials_instrumenter == :keep
          raise ArgumentError, "Smith.config.require_run_credentials refuses run_credentials_instrumenter :keep"
        end

        value
      end
    end

    # Whether a credentialed run's RubyLLM context keeps RubyLLM's
    # instrumenter: :off (none, so no subscriber sees a raw request) or
    # :keep, which the fail-closed mode refuses.
    def run_credentials_instrumenter
      lambda do |value|
        unless %i[off keep].include?(value)
          raise ArgumentError, "Smith.config.run_credentials_instrumenter must be :off or :keep, got #{value.inspect}"
        end

        if value == :keep && Smith.config.require_run_credentials
          raise ArgumentError, "Smith.config.run_credentials_instrumenter :keep is refused while " \
                               "require_run_credentials is on"
        end

        value
      end
    end

    # A host adapter: nil, or an object that answers `calls` (each named
    # with its arguments, as the message says).
    def adapter(name, calls)
      lambda do |value|
        next value if value.nil? || calls.keys.all? { value.respond_to?(_1) }

        raise ArgumentError, "Smith.config.#{name} must respond to #{calls.values.join(" and ")}"
      end
    end
  end
end
