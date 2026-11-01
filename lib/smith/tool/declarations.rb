# frozen_string_literal: true

module Smith
  class Tool < RubyLLM::Tool
    # A tool class's declarations, which its subclasses inherit: each reads
    # the nearest class up the chain that declared it, so a subclass
    # overrides one by declaring it again. Parameters add up by name (a
    # subclass's `param` adds one or replaces its parent's of that name), and
    # a schema given with `params` gives way to the subclass's own `param`s.
    # Capabilities (CapabilityDeclaration) merge key by key, and a capture
    # (CaptureConfiguration) comes with its strictness. A tool none of whose
    # classes declares `authorize` or `before_execute` runs without one, as
    # before. `O(D)` for a chain `D` classes deep.
    module Declarations
      def description(text = nil)
        return declared(:@description) unless text

        @description = text
      end
      alias desc description

      def param(name, **) = own_parameters[name] = RubyLLM::Parameter.new(name, **)

      def parameters
        inherited = parent_tool&.parameters
        inherited.nil? || inherited.empty? ? own_parameters : inherited.merge(own_parameters)
      end

      def params_schema_definition
        return @params_schema_definition if instance_variable_defined?(:@params_schema_definition)

        parent_tool&.params_schema_definition if own_parameters.empty?
      end

      def provider_params = declared(:@provider_params) || {}

      def category(value = nil)
        return declared(:@category) if value.nil?

        @category = value
      end

      def authorize(&block)
        return declared(:@authorize) unless block

        @authorize = block
      end

      def before_execute(&block)
        return declared(:@before_execute) unless block

        @before_execute = block
      end

      private

      def own_parameters = (@own_parameters ||= {})

      def parent_tool = (superclass if superclass <= Tool)

      # The nearest class from this one up that set `ivar`, or nil.
      def declaring_tool(ivar)
        tool = self
        tool = tool.__send__(:parent_tool) while tool && !tool.instance_variable_defined?(ivar)
        tool
      end

      def declared(ivar) = declaring_tool(ivar)&.instance_variable_get(ivar)
    end
  end
end
