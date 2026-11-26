# frozen_string_literal: true

module Smith
  module Prompts
    # Internal. An attempt's version stamp, [{id:, version:}] with Symbol
    # keys, frozen: the named prompt versions it was built to send. Worked
    # out once an attempt (Prompts.sending) and handed to every record of
    # it; read back by one rule, so a saved run or a branch's results hold
    # no other shape. O(C) for C components.
    module Stamp
      module_function

      # A resolved named prompt's stamp.
      def of(prompt) = [{ id: prompt.component_id, version: prompt.version }.freeze].freeze

      # The stamp of an agent without a named prompt: the components its
      # class gives (a definition's), or nil.
      def given(agent_class)
        components = agent_class.smith_prompt_components if agent_class.respond_to?(:smith_prompt_components)
        return if components.nil?

        listed = components.map { _1.is_a?(Data) ? _1.to_h : _1 } if components.is_a?(Array)
        read(listed) || raise(PromptInvalid, "#{agent_class} gives prompt components that are not {id, version} pairs")
      end

      # A stamp as Smith records one, from one read back or given: each
      # component an id and a version, at most MAX_COMPONENTS; nil for any
      # other shape.
      def read(value)
        return unless value.is_a?(Array) && value.size <= MAX_COMPONENTS

        stamp = value.map { component(_1) }
        stamp.freeze if stamp.all?
      end

      # Stamps kept by request id (a pending batch's), each read back, every
      # id one of `requests`' keys; nil for any other shape.
      def by_id(value, requests)
        return unless value.is_a?(Hash) && !value.empty? && requests.is_a?(Hash)

        stamps = value.to_h { |id, stamp| [id.to_s, read(stamp)] }
        stamps.freeze if stamps.values.all? && (stamps.keys - requests.keys).empty?
      end

      def component(value)
        pair = value.to_h { |key, item| [key.to_s, item] } if value.is_a?(Hash) && value.size == 2
        id, version = pair&.values_at("id", "version")
        return unless matches?(ContentIdentity::ID, id) && matches?(ContentIdentity::DIGEST, version)

        { id: id.dup.freeze, version: version.dup.freeze }.freeze
      end

      def matches?(rule, value) = value.is_a?(String) && rule.match?(value)
    end
  end
end
