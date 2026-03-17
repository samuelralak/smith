# frozen_string_literal: true

require "ruby_llm"

module Smith
  class Agent < RubyLLM::Agent
    class << self
      def inherited(subclass)
        super
        subclass.instance_variable_set(:@budget_config, @budget_config)
        subclass.instance_variable_set(:@guardrails_class, @guardrails_class)
        subclass.instance_variable_set(:@output_schema_class, @output_schema_class)
        subclass.instance_variable_set(:@registered_name, nil)
      end

      def budget(**opts)
        return @budget_config if opts.empty?

        @budget_config = opts
      end

      def guardrails(klass = nil)
        return @guardrails_class if klass.nil?

        @guardrails_class = klass
      end

      def output_schema(klass = nil)
        return @output_schema_class if klass.nil?

        @output_schema_class = klass
      end

      def register_as(name = nil)
        return @registered_name if name.nil?

        @registered_name = name
        Registry.register(name.to_sym, self)
      end
    end
  end
end
