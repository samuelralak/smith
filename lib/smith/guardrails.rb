# frozen_string_literal: true

module Smith
  class Guardrails
    class << self
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
