# frozen_string_literal: true

require_relative "content"
require_relative "errors"
require_relative "workflow/message_roles"

module Smith
  # Messages for a step's `input:` and the `seed_messages` builder. Content
  # is a String, or an Array of 1 to MAX_PARTS Smith::Content parts:
  #
  #   Smith::Message.user("Summarize the contract.")
  #   Smith::Message.system([Smith::Content.text(style_guide, cache: true)])
  #
  # A message with parts carries `"parts" => true` beside its role and
  # content. No agent output and no message a host admits
  # (`append_session_messages!`) can carry it, so a structured output that
  # looks like parts stays data. A system message takes text parts only.
  module Message
    MAX_PARTS = 100

    module_function

    def user(content) = build("user", content)

    def assistant(content) = build("assistant", content)

    def system(content) = build("system", content)

    def build(role, content)
      return { "role" => role, "content" => content.dup.freeze }.freeze if content.is_a?(String)

      check!({ "role" => role, "content" => content, "parts" => true })
    end

    # Whether a message Hash (String or Symbol keys) is one with parts.
    def parts?(message)
      message.is_a?(Hash) && (message.key?("parts") || message.key?(:parts))
    end

    # A message with parts, checked and returned frozen with String keys.
    def check!(message)
      fields = message.is_a?(Hash) ? message.transform_keys(&:to_s) : {}
      role = Workflow::MessageRoles.role(fields, %w[system user assistant])
      unless role && shaped?(fields)
        raise WorkflowError, "a message with content parts is { role:, content: [parts], parts: true } with a " \
                             "system, user or assistant role and 1 to #{MAX_PARTS} parts"
      end

      { "role" => role, "content" => checked_parts(role, fields["content"]), "parts" => true }.freeze
    end

    def shaped?(fields)
      content = fields["content"]
      fields.keys.sort == %w[content parts role] && fields["parts"] == true && content.is_a?(Array) &&
        content.length.between?(1, MAX_PARTS)
    end

    def checked_parts(role, content)
      parts = content.map { |part| Content.check!(part) }.freeze
      return parts unless role == "system" && parts.any? { |part| part["type"] != "text" }

      raise WorkflowError, "a system message takes text parts only"
    end
    private_class_method :build, :shaped?, :checked_parts
  end
end
