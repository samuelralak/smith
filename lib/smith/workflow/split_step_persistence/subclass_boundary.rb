# frozen_string_literal: true

module Smith
  class Workflow
    module SplitStepPersistence
      module SubclassBoundary
        def self.guard
          Module.new.tap do |guard|
            instance_methods(false).each do |method_name|
              guard.define_method(method_name, instance_method(method_name))
            end
            private_instance_methods(false).each do |method_name|
              guard.define_method(method_name, instance_method(method_name))
              guard.send(:private, method_name)
            end
          end
        end

        def to_state
          state = super
          split_step_boundary_active? ? snapshot_value(state) : state
        end

        def advance!
          SplitStepPersistence.instance_method(:guard_split_step_subclass_execution!).bind_call(self)
          super
        end

        def run!
          SplitStepPersistence.instance_method(:guard_split_step_subclass_execution!).bind_call(self)
          super
        end

        private

        def effective_persistence_ttl
          return super unless split_step_boundary_active?
          return super unless instance_variable_defined?(:@split_step_persistence_ttl)

          @split_step_persistence_ttl
        end

        def ttl_kwarg(ttl)
          return super unless split_step_boundary_active?
          return super unless instance_variable_defined?(:@split_step_persistence_ttl)

          { ttl: ttl }
        end

        def dispatch_store!(...)
          DispatchBoundary.instance_method(:dispatch_store!).bind_call(self, ...)
        end
      end
    end
  end
end
