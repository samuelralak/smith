# frozen_string_literal: true

require "dry-initializer"

module Smith
  class Agent
    class RegistryBinding
      extend Dry::Initializer

      option :key
      option :item

      def to_h
        {
          key: key,
          agent_class: agent_class,
          call: call?,
          raw_binding: raw_binding
        }.freeze
      end

      private

      def agent_class
        return unless call? == false

        raw_binding if raw_binding.is_a?(Class) && raw_binding <= Smith::Agent
      end

      def call?
        options.fetch(:call, true)
      end

      def raw_binding
        item.instance_variable_get(:@item)
      end

      def options
        item.instance_variable_get(:@options) || {}
      end
    end
  end
end
