# frozen_string_literal: true

module Smith
  class Workflow
    class StringSnapshot
      BYTESIZE = String.instance_method(:bytesize)
      FREEZE = String.instance_method(:freeze)
      INITIALIZE_COPY = String.instance_method(:initialize_copy)
      private_constant :BYTESIZE, :FREEZE, :INITIALIZE_COPY

      class << self
        def bytesize(value)
          BYTESIZE.bind_call(value)
        end

        def copy(value, freeze: false)
          String.allocate.tap do |copy|
            INITIALIZE_COPY.bind_call(copy, value)
            FREEZE.bind_call(copy) if freeze
          end
        end
      end
    end
  end
end
