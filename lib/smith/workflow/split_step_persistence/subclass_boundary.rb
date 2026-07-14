# frozen_string_literal: true

module Smith
  class Workflow
    module SplitStepPersistence
      module SubclassBoundary
        class << self
          def protect_execution_path!(workflow_class, *owners)
            protected_method_names(owners).each do |method_name|
              protect_method!(workflow_class, method_name)
            end
          end

          private

          def protected_method_names(owners)
            owners.flat_map do |owner|
              owner.private_instance_methods(false) + owner.protected_instance_methods(false)
            end.uniq
          end

          def protect_method!(workflow_class, method_name)
            return if boundary_method_names.include?(method_name)

            implementation = workflow_class.instance_method(method_name)
            define_method(method_name) do |*arguments, **keywords, &block|
              active = SubclassBoundary
                       .instance_method(:smith_prepared_execution_active?)
                       .bind_call(self)
              if active
                implementation.bind_call(self, *arguments, **keywords, &block)
              else
                super(*arguments, **keywords, &block)
              end
            end
            private method_name
          end

          def boundary_method_names
            instance_methods(false) + private_instance_methods(false) + protected_instance_methods(false)
          end
        end

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

        def smith_prepared_execution_active?
          root_execution = @split_step_phase == :executing &&
                           @split_step_execution_thread.equal?(Thread.current)
          return true if root_execution

          authorization = @split_step_active_execution_authorization
          authorization&.issued_in_current_process? == true
        end

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
