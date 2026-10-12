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
