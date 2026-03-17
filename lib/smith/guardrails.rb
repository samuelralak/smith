# frozen_string_literal: true

module Smith
  class Guardrails
    class << self
      def inherited(subclass)
        super
        subclass.instance_variable_set(:@inputs, (@inputs || []).dup)
        subclass.instance_variable_set(:@tools, (@tools || []).dup)
        subclass.instance_variable_set(:@outputs, (@outputs || []).dup)
      end

      def input(name = nil, **)
        return @inputs || [] if name.nil?

        @inputs ||= []
        @inputs << ({ name: name, ** })
      end

      def tool(name = nil, **)
        return @tools || [] if name.nil?

        @tools ||= []
        @tools << ({ name: name, ** })
      end

      def output(name = nil, **)
        return @outputs || [] if name.nil?

        @outputs ||= []
        @outputs << ({ name: name, ** })
      end
    end
  end
end
