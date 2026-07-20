# frozen_string_literal: true

module Smith
  class Workflow
    module ProcessLocal
      def initialize_copy(_source)
        raise TypeError, "#{self.class} cannot be copied"
      end

      def _dump(_depth)
        raise TypeError, "#{self.class} cannot be serialized"
      end

      def encode_with(_coder)
        raise TypeError, "#{self.class} cannot be serialized"
      end

      def init_with(_coder)
        raise TypeError, "#{self.class} cannot be deserialized"
      end

      def as_json(*)
        raise TypeError, "#{self.class} cannot be serialized"
      end

      def to_json(*)
        raise TypeError, "#{self.class} cannot be serialized"
      end
    end

    private_constant :ProcessLocal
  end
end
