# frozen_string_literal: true

module Smith
  class Context
    class << self
      def inherited(subclass)
        super
        subclass.instance_variable_set(:@session_strategy, @session_strategy)
        subclass.instance_variable_set(:@persist_keys, (@persist_keys || []).dup)
        subclass.instance_variable_set(:@inject_state, @inject_state)
      end

      def session_strategy(strategy = nil, **opts)
        return @session_strategy if strategy.nil?

        @session_strategy = { strategy: strategy, **opts }
      end

      def persist(*keys)
        return @persist_keys || [] if keys.empty?

        @persist_keys ||= []
        @persist_keys.concat(keys)
      end

      def inject_state(&block)
        return @inject_state unless block_given?

        @inject_state = block
      end
    end
  end
end
