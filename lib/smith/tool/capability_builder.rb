# frozen_string_literal: true

module Smith
  class Tool < RubyLLM::Tool
    class CapabilityBuilder
      def initialize
        @capabilities = {}
      end

      def sensitivity(value)  = @capabilities[:sensitivity] = value
      def privilege(value)    = @capabilities[:privilege] = value
      def network(value)      = @capabilities[:network] = value
      def approval(value)     = @capabilities[:approval] = value
      def data_volume(value)  = @capabilities[:data_volume] = value
      def to_h                = @capabilities
    end
  end
end
