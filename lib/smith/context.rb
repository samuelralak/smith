# frozen_string_literal: true

module Smith
  class Context
    class << self
      def inherited(subclass)
        super
        subclass.instance_variable_set(:@session_strategy, @session_strategy)
        subclass.instance_variable_set(:@persist_keys, (@persist_keys || []).dup)
        subclass.instance_variable_set(:@persist_mode, @persist_mode || :explicit)
        subclass.instance_variable_set(:@persist_auto_seed, (@persist_auto_seed || []).dup)
        subclass.instance_variable_set(:@inject_state, @inject_state)
      end

      def session_strategy(strategy = nil, **opts)
        return @session_strategy if strategy.nil?

        @session_strategy = { strategy: strategy, **opts }
      end

      def persist(*keys, also: nil)
        if keys.empty? && also.nil?
          return @persist_keys || []
        end

        if also && !keys.include?(:auto)
          raise Smith::WorkflowError, ":also is only valid alongside :auto"
        end

        if keys.include?(:auto)
          other_keys = keys.reject { |k| k == :auto }
          unless other_keys.empty?
            raise Smith::WorkflowError, "persist :auto must be the sole positional argument; got #{other_keys.inspect}"
          end
          @persist_mode = :auto
          @persist_keys = []
          @persist_auto_seed = Array(also).map(&:to_sym)
          return @persist_auto_seed.dup
        end

        @persist_mode = :explicit
        @persist_keys ||= []
        @persist_keys.concat(keys)
      end

      def persist_mode
        @persist_mode || :explicit
      end

      def persist_auto_seed
        @persist_auto_seed || []
      end

      def inject_state(&block)
        return @inject_state unless block_given?

        @inject_state = block
      end
    end
  end
end
