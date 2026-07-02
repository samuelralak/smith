# frozen_string_literal: true

require "dry-container"
require "monitor"
require_relative "registry_binding"

module Smith
  class Agent
    module Registry
      extend Dry::Container::Mixin

      def self.normalize_key(name)
        name.to_s
      end

      def self.find(name)
        registry_monitor.synchronize do
          registered_binding(normalize_key(name))
        end
      end

      def self.register(key, contents = nil, options = {}, &block)
        if block_given? || !(contents.is_a?(Class) && contents <= Smith::Agent)
          registry_monitor.synchronize { super(key, contents, options, &block) }
        else
          ensure_registered(key, contents)
        end
      end

      def self.delete(name)
        registry_monitor.synchronize do
          _container.delete(normalize_key(name))
        end
      end

      def self.clear!
        registry_monitor.synchronize do
          @_container&.clear
        end
      end

      def self.ensure_registered(name, klass)
        validate_agent_class!(klass)
        key = normalize_key(name)

        registry_monitor.synchronize do
          existing = registered_binding(key)

          if existing.nil?
            register_unchecked!(key, klass)
          elsif existing.equal?(klass)
            # same object — no-op
          elsif stale_reload_binding?(existing, klass)
            # same class name, different object — Rails reload case
            _container.delete(key)
            register_unchecked!(key, klass)
          else
            raise Smith::AgentRegistryError,
                  "agent registry collision for key #{key.inspect}: " \
                  "already registered to #{binding_label(existing)}, " \
                  "cannot replace with #{binding_label(klass)}"
          end

          klass
        end
      end

      def self.fetch!(name, workflow_class: nil, transition_name: nil, role: :agent)
        registry_monitor.synchronize do
          key = normalize_key(name)
          binding = registered_binding(key)
          return binding if binding

          raise Smith::WorkflowError, "unresolved #{role} :#{key}#{fetch_suffix(workflow_class, transition_name)}"
        end
      end

      def self.registry_monitor
        @registry_monitor ||= Monitor.new
      end

      def self.validate_agent_class!(klass)
        return if klass.is_a?(Class) && klass <= Smith::Agent

        raise Smith::AgentRegistryError,
              "expected a Smith::Agent subclass, got #{klass.inspect}"
      end

      # Safe label for collision error messages. Handles both classes
      # (which respond to .name) and plain values (which do not).
      def self.binding_label(value)
        if value.respond_to?(:name) && value.name.is_a?(String) && !value.name.empty?
          value.name
        else
          value.inspect
        end
      end
      private_class_method :binding_label

      # Private raw registration that bypasses ensure_registered.
      # Used internally to avoid recursion/deadlock.
      # Caller MUST already hold registry_monitor.
      def self.register_unchecked!(key, klass)
        config.registry.call(_container, key, klass, {})
      end
      private_class_method :register_unchecked!

      def self.registered_binding(key)
        key?(key) ? resolve(key) : nil
      end
      private_class_method :registered_binding

      def self.fetch_suffix(workflow_class, transition_name)
        details = []
        details << "workflow #{workflow_class}" if workflow_class
        details << "transition :#{transition_name}" if transition_name
        details.empty? ? "" : " for #{details.join(", ")}"
      end
      private_class_method :fetch_suffix

      def self.stale_reload_binding?(existing, klass)
        existing_name = existing.respond_to?(:name) ? existing.name : nil
        klass_name = klass.name
        existing_name.is_a?(String) && !existing_name.empty? &&
          klass_name.is_a?(String) && !klass_name.empty? &&
          existing_name == klass_name
      end
      private_class_method :stale_reload_binding?
    end
  end
end

require_relative "registry/introspection"
