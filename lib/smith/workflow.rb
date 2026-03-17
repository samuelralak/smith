# frozen_string_literal: true

module Smith
  class Workflow
    class << self
      def inherited(subclass)
        super
        subclass.instance_variable_set(:@states, (@states || []).dup)
        subclass.instance_variable_set(:@transitions, (@transitions || {}).dup)
        subclass.instance_variable_set(:@initial_state_name, @initial_state_name)
        subclass.instance_variable_set(:@budget_config, @budget_config&.dup)
        subclass.instance_variable_set(:@max_transitions_count, @max_transitions_count)
        subclass.instance_variable_set(:@guardrails_class, @guardrails_class)
        subclass.instance_variable_set(:@context_manager_class, @context_manager_class)
      end

      def initial_state(name = nil)
        return @initial_state_name if name.nil?

        @initial_state_name = name
        state(name)
      end

      def state(name)
        @states ||= []
        @states << name unless @states.include?(name)
      end

      def transition(name, from:, to:, &)
        @transitions ||= {}
        @transitions[name] = Transition.new(name, from: from, to: to, &)
      end

      def budget(**opts)
        return @budget_config if opts.empty?

        @budget_config = opts
      end

      def max_transitions(count = nil)
        return @max_transitions_count if count.nil?

        @max_transitions_count = count
      end

      def guardrails(klass = nil)
        return @guardrails_class if klass.nil?

        @guardrails_class = klass
      end

      def context_manager(klass = nil)
        return @context_manager_class if klass.nil?

        @context_manager_class = klass
      end

      def from_state(hash)
        workflow = allocate
        workflow.send(:restore_state, hash)
        workflow
      end
    end

    def initialize(context: {})
      @state = self.class.send(:instance_variable_get, :@initial_state_name)
      @context = context
      @budget_consumed = {}
      @step_count = 0
      @created_at = Time.now.utc.iso8601
      @updated_at = @created_at
    end

    def advance!
      @step_count += 1
      @updated_at = Time.now.utc.iso8601
    end

    def run!
      advance! until terminal?
    end

    attr_reader :state

    def to_state
      {
        class: self.class.name,
        state: @state,
        context: @context,
        budget_consumed: @budget_consumed,
        step_count: @step_count,
        created_at: @created_at,
        updated_at: @updated_at
      }
    end

    private

    def restore_state(hash)
      @state = hash[:state]
      @context = hash[:context] || {}
      @budget_consumed = hash[:budget_consumed] || {}
      @step_count = hash[:step_count] || 0
      @created_at = hash[:created_at]
      @updated_at = hash[:updated_at]
    end

    def terminal?
      true
    end
  end
end
