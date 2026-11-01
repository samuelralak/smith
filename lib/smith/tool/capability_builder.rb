# frozen_string_literal: true

module Smith
  class Tool < RubyLLM::Tool
    class CapabilityBuilder
      REPLAY = %i[safe unsafe].freeze
      private_constant :REPLAY

      def initialize
        @capabilities = {}
      end

      def sensitivity(value)  = @capabilities[:sensitivity] = value
      def privilege(value)    = @capabilities[:privilege] = value
      def network(value)      = @capabilities[:network] = value
      def approval(value)     = @capabilities[:approval] = value
      def data_volume(value)  = @capabilities[:data_volume] = value

      # :safe when running the tool again under the same keys does what
      # running it once did (a lookup), so a step whose tools are all safe
      # keeps its retries and fallbacks; :unsafe, the default, otherwise.
      def replay(value)
        raise ArgumentError, "replay is :safe or :unsafe" unless REPLAY.include?(value)

        @capabilities[:replay] = value
      end

      def to_h = @capabilities
    end
  end
end
