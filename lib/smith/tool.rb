# frozen_string_literal: true

require "ruby_llm"

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

    class << self
      def category(value = nil)
        return @category if value.nil?

        @category = value
      end

      def capabilities(&)
        return @capabilities unless block_given?

        builder = CapabilityBuilder.new
        builder.instance_eval(&)
        @capabilities = builder.to_h
      end

      def authorize(&block)
        return @authorize unless block_given?

        @authorize = block
      end
    end

    def execute(**kwargs)
      check_authorization!(kwargs)
      perform(**kwargs)
    end

    private

    def check_authorization!(kwargs)
      authorizer = self.class.authorize
      return unless authorizer

      context = kwargs[:context]
      raise ToolPolicyDenied unless authorizer.call(context)
    end

    def perform(**kwargs)
      raise NotImplementedError, "#{self.class} must implement #perform"
    end
  end
end
