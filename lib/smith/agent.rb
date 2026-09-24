# frozen_string_literal: true

require "ruby_llm"

require_relative "tool"

module Smith
  class Agent < RubyLLM::Agent
    require_relative "agent/model_reference"

    EXECUTION_IDENTITY_UNSET = Object.new.freeze
    TOOL_BUDGET_EXHAUSTION_UNSET = Object.new.freeze
    TOOL_BUDGET_EXHAUSTION_POLICIES = %i[raise complete].freeze
    BUDGET_KEYS = %i[token_limit cost wall_clock tool_calls total_tokens total_cost].freeze

    private_constant :EXECUTION_IDENTITY_UNSET
    private_constant :TOOL_BUDGET_EXHAUSTION_UNSET, :TOOL_BUDGET_EXHAUSTION_POLICIES, :BUDGET_KEYS

    # Reserved input names auto-injected by the normalizer into
    # runtime_context. User-side `inputs :name` calls cannot redeclare
    # these names; the override raises Smith::AgentError if they try.
    # The getter merges user-declared inputs WITH reserved so subclasses
    # don't lose reserved names when declaring their own.
    RESERVED_INPUT_NAMES = %i[model_id provider endpoint_mode].freeze

    class << self
      def inherited(subclass)
        super
        subclass.instance_variable_set(:@budget_config, @budget_config)
        subclass.instance_variable_set(:@guardrails_class, @guardrails_class)
        subclass.instance_variable_set(:@output_schema_class, @output_schema_class)
        subclass.instance_variable_set(:@data_volume, @data_volume)
        subclass.instance_variable_set(:@fallback_models_list, @fallback_models_list&.dup&.freeze)
        subclass.instance_variable_set(:@fallback_models_block, @fallback_models_block)
        subclass.instance_variable_set(:@model_block, @model_block)
        subclass.instance_variable_set(:@tool_budget_exhaustion, @tool_budget_exhaustion)
        subclass.instance_variable_set(:@execution_identity, nil)
        subclass.instance_variable_set(:@registered_name, nil)
      end

      def execution_identity(value = EXECUTION_IDENTITY_UNSET)
        return @execution_identity if value.equal?(EXECUTION_IDENTITY_UNSET)
        unless value.is_a?(String) && /\A[0-9a-f]{64}\z/.match?(value)
          raise ArgumentError, "execution_identity must be a lowercase SHA-256 hex digest"
        end

        @execution_identity = value.dup.freeze
      end

      def budget(**opts)
        return @budget_config if opts.empty?

        unknown = opts.keys - BUDGET_KEYS
        unless unknown.empty?
          raise ArgumentError, "agent budget does not accept #{unknown.map(&:inspect).join(", ")}; " \
                               "accepted keys are #{BUDGET_KEYS.map(&:inspect).join(", ")}"
        end

        @budget_config = opts
      end

      def tool_budget_exhaustion(value = TOOL_BUDGET_EXHAUSTION_UNSET)
        return @tool_budget_exhaustion || :raise if value.equal?(TOOL_BUDGET_EXHAUSTION_UNSET)

        policy = value.respond_to?(:to_sym) ? value.to_sym : value
        unless TOOL_BUDGET_EXHAUSTION_POLICIES.include?(policy)
          raise ArgumentError, "tool_budget_exhaustion must be :raise or :complete"
        end

        @tool_budget_exhaustion = policy
      end

      def guardrails(klass = nil)
        return @guardrails_class if klass.nil?

        @guardrails_class = klass
      end

      def output_schema(klass = nil)
        return @output_schema_class if klass.nil?

        @output_schema_class = klass
      end

      def data_volume(value = nil)
        return @data_volume if value.nil?

        @data_volume = value
      end

      def register_as(name = nil, publish: true)
        return @registered_name if name.nil?

        raise ArgumentError, "publish must be true or false" unless [true, false].include?(publish)

        @registered_name = canonical_registration_name(name)
        publish ? publish_registration! : self
      end

      def publish_registration!
        name = @registered_name
        raise Smith::AgentRegistryError, "agent registration identity is not configured" unless name

        Registry.ensure_registered(name.to_sym, self)
      end

      private

      def canonical_registration_name(name)
        symbol = name.to_sym
        raise TypeError, "agent registration name must convert to a Symbol" unless symbol.is_a?(Symbol)

        name.is_a?(String) ? name.dup.freeze : symbol
      rescue NoMethodError
        raise TypeError, "agent registration name must respond to #to_sym"
      end

      public

      # MERGING override: getter always returns user-declared ∪ reserved;
      # setter validates user names against reserved + stores only user
      # names. RubyLLM's bare `@input_names = names` (agent.rb:96) REPLACES;
      # this override prevents subclasses from losing reserved names when
      # they declare their own inputs.
      def inputs(*names)
        if names.empty?
          user = @input_names || []
          return (user + RESERVED_INPUT_NAMES).uniq.freeze
        end

        user_names = names.flatten.map(&:to_sym)
        collisions = user_names & RESERVED_INPUT_NAMES
        if collisions.any?
          raise Smith::AgentError,
                "agent input names #{collisions.inspect} are reserved by Smith. " \
                "Reserved names #{RESERVED_INPUT_NAMES.inspect} are auto-injected by " \
                "Smith::Models::Normalizer into runtime_context. " \
                "Rename your inputs to avoid the collision."
        end

        @input_names = user_names.freeze
      end
    end
  end
end

require_relative "agent/dynamic_configuration"
require_relative "agent/fallback_configuration"
require_relative "agent/reserved_input_bridge"
require_relative "agent/chat_construction"

Smith::Agent.extend(Smith::Agent::DynamicConfiguration)
Smith::Agent.extend(Smith::Agent::FallbackConfiguration)
Smith::Agent.extend(Smith::Agent::ReservedInputBridge)
Smith::Agent.extend(Smith::Agent::ChatConstruction)
