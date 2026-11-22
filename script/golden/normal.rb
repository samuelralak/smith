# frozen_string_literal: true

require "bigdecimal"

module CoreInvisibility
  # Plain JSON values for the golden document. Hash order is kept (it is
  # behaviour); Symbols, as values and as keys, read ":name"; times read
  # ISO 8601 with microseconds; an error reads its class, message and causes;
  # Struct, Data and Dry::Struct values read their fields. Any other object
  # raises, so a sink that starts holding one is taught here instead of
  # hiding its content. Bounded by depth; linear in the value's size.
  module Normal
    MAX_DEPTH = 64

    module_function

    def value(object, depth = 0)
      raise ArgumentError, "value nested deeper than #{MAX_DEPTH}" if depth > MAX_DEPTH

      case object
      when Hash then object.each_with_object({}) { |(key, item), out| out[key(key)] = value(item, depth + 1) }
      when Array, Set then object.map { value(_1, depth + 1) }
      else scalar(object, depth)
      end
    end

    def scalar(object, depth)
      case object
      when nil, true, false, Integer then object
      when String then text(object)
      when Float then object.finite? ? object : object.to_s
      when Symbol then ":#{object}"
      else other(object, depth)
      end
    end

    def other(object, depth)
      case object
      when Time then object.utc.iso8601(6)
      when BigDecimal then "decimal:#{object.to_s("F")}"
      when Exception then error(object)
      when Module then object.name || "anonymous"
      else structured(object, depth)
      end
    end

    def structured(object, depth)
      return value(object.to_h, depth + 1).merge("class" => object.class.name) if structured?(object)

      raise ArgumentError, "the harness cannot record a #{object.class}; teach CoreInvisibility::Normal"
    end

    def structured?(object)
      object.is_a?(Struct) || object.is_a?(Data) || (defined?(Dry::Struct) && object.is_a?(Dry::Struct))
    end

    def key(key) = key.is_a?(Symbol) ? ":#{key}" : key.to_s

    # Bytes that are not UTF-8 are shown as hex, so the document stays JSON.
    def text(string)
      utf8 = string.encoding == Encoding::UTF_8 ? string : string.dup.force_encoding(Encoding::UTF_8)
      utf8.valid_encoding? ? utf8 : "bytes:#{string.unpack1("H*")}"
    end

    def error(error)
      causes = []
      cause = error.cause
      while cause && causes.length < 8
        causes << { "class" => cause.class.name, "message" => text(cause.message.to_s) }
        cause = cause.cause
      end
      { "class" => error.class.name, "message" => text(error.message.to_s), "causes" => causes }
    end
  end
end
