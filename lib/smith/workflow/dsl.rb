# frozen_string_literal: true

module Smith
  class Workflow
    module DSL
      def self.included(base)
        base.extend(ClassMethods)
      end

      module ClassMethods
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
          generate_fail_transition if name == :failed
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

        def transitions_from(state)
          (@transitions || {}).values.select { |t| t.from == state }
        end

        def find_transition(name)
          (@transitions || {})[name]
        end

        def from_state(hash)
          workflow = allocate
          workflow.send(:restore_state, hash)
          workflow
        end

        private

        def generate_fail_transition
          @transitions ||= {}
          return if @transitions.key?(:fail)

          @transitions[:fail] = Transition.new(:fail, from: nil, to: :failed)
        end
      end
    end
  end
end
