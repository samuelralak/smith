# frozen_string_literal: true

require "json"

module Smith
  class Agent
    module InvocationPreparation
      WORKFLOW_CONTINUATION_MESSAGE =
        "Use the preceding assistant result as input and perform your assigned workflow step."

      private_constant :WORKFLOW_CONTINUATION_MESSAGE

      private

      def bridge_workflow_inputs(agent_class)
        return {} unless @context.is_a?(Hash)

        declared = agent_class.inputs || []
        user_declared = declared - Smith::Agent::RESERVED_INPUT_NAMES
        user_declared.to_h do |name|
          [name, @context[name]]
        end
      end

      def add_prepared_input(chat, prepared_input)
        return unless prepared_input

        prepared_input = provider_safe_prepared_input(prepared_input)
        system_messages, other_messages = prepared_input.partition do |message|
          message_role(message) == :system
        end

        merge_system_messages!(chat, system_messages) if system_messages.any?
        other_messages.each { |message| add_message(chat, message) }
      end

      def provider_safe_prepared_input(prepared_input)
        messages = prepared_input.to_a
        return messages unless workflow_handoff?(messages)

        messages + [{ role: :user, content: WORKFLOW_CONTINUATION_MESSAGE }]
      end

      def workflow_handoff?(messages)
        message = messages.reverse_each.find { |candidate| message_role(candidate) != :system }
        return false unless message
        return false unless message_role(message) == :assistant
        return false unless defined?(@last_output) && !@last_output.nil?

        message_content(message) == @last_output
      end

      def merge_system_messages!(chat, prepared_system_messages)
        return append_system_messages(chat, prepared_system_messages) unless chat.respond_to?(:messages)

        combined_contents = existing_system_contents(chat) + prepared_system_contents(prepared_system_messages)
        return if combined_contents.empty?
        return append_system_messages(chat, prepared_system_messages) unless combined_contents.all?(String)

        if chat.respond_to?(:with_instructions)
          chat.with_instructions(combined_contents.join("\n\n"))
        else
          append_system_messages(chat, prepared_system_messages)
        end
      end

      def append_system_messages(chat, messages)
        messages.each { |message| add_message(chat, message) }
      end

      def existing_system_contents(chat)
        chat.messages.filter_map do |message|
          message.content if message_role(message) == :system
        end
      end

      def prepared_system_contents(messages)
        messages.filter_map { |message| message_content(message) }
      end

      def add_message(chat, message)
        attributes = if message.is_a?(Hash)
                       message.transform_keys { |key| key.respond_to?(:to_sym) ? key.to_sym : key }
                     else
                       message
                     end
        attributes = provider_safe_message(attributes) if attributes.is_a?(Hash)
        chat.add_message(attributes)
      end

      # A structured agent output recorded as a session message (StepCompletion#append_accepted_output)
      # carries a Hash/Array content. RubyLLM's Message#normalize_content treats a Hash content as
      # { text:, ...attachments } and opens each value as a file, so replaying a prior structured
      # output to the next agent in a workflow session raises Errno::ENOENT. Serialize non-string
      # content to JSON so the provider sees the prior output as text; the session store keeps the raw
      # value (last_output stays structured), only this provider-facing copy is serialized. Genuine
      # multimodal attachments are supplied through the provider's own with: mechanism, never as a bare
      # Hash message content in a workflow session.
      def provider_safe_message(attributes)
        content = attributes[:content]
        return attributes if content.nil? || content.is_a?(String)

        attributes.merge(content: json_message_content(content))
      end

      def json_message_content(content)
        JSON.generate(content)
      rescue StandardError
        content.to_s
      end

      def message_role(message)
        message_attribute(message, :role)&.to_sym
      end

      def message_content(message)
        message_attribute(message, :content)
      end

      def message_attribute(message, name)
        return message.public_send(name) if message.respond_to?(name)
        return message[name] if message.respond_to?(:key?) && message.key?(name)

        message[name.to_s]
      end
    end
  end
end
