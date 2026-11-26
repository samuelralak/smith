# frozen_string_literal: true

require_relative "../../template"

module Smith
  module Definitions
    class Validator
      # The prompt: named components in the order they are sent, each a
      # system or user text of logic-less fill-in fields (Smith::Template)
      # naming declared inputs (unchecked when the inputs cannot be read), a
      # system one only trusted inputs, and at least one user component. No
      # assistant prefill, which no export target takes. O(L) for L bytes of
      # text.
      class PromptCheck
        include Checks

        # `trusted`: each declared input and whether it is trusted, or nil.
        def initialize(problems, trusted)
          @problems = problems
          @trusted = trusted
          @templates = {}
          @ids = Set.new
        end

        # Each component's template, by component id.
        def templates(prompt)
          return unless list!(prompt, "/prompt")

          prompt.each_with_index { |component, index| component!(component, "/prompt/#{index}") }
          need(prompt.any? { _1.is_a?(Hash) && _1["role"] == "user" }, "/prompt", "holds no user component")
          @templates.freeze
        end

        private

        def component!(component, path)
          return unless object!(component, path)

          fields!(component, path, COMPONENT_FIELDS, "a field of a prompt component")
          id = required(component, "component_id", path) { id!(_1, "#{path}/component_id") }
          role = required(component, "role", path) { need(ROLES.include?(_1), "#{path}/role", "is system or user") }
          template = required(component, "text", path) { template!(_1, "#{path}/text") }
          fields_in!(template, component["role"], "#{path}/text") if template && role && @trusted
          @templates[id] = template if id && template
          annotations!(component, path)
        end

        def id!(id, path)
          return problem(path, ID_RULE) unless id.is_a?(String) && ID.match?(id)
          return problem(path, "#{shown(id)} is used twice") unless @ids.add?(id)

          id
        end

        def template!(text, path)
          return problem(path, "is a String with more than white space") unless text.is_a?(String) && text.match?(/\S/)
          return problem(path, "is more than #{MAX_TEXT_BYTES} bytes") if text.bytesize > MAX_TEXT_BYTES

          refused = Template.problems(text)
          return Template.new(text) if refused.empty?

          refused.each { problem(path, _1) }
          nil
        end

        def fields_in!(template, role, path)
          return problem(path, "holds more than #{MAX_FIELDS} fill-in fields") if template.field_count > MAX_FIELDS

          template.fields.each do |field|
            next problem(path, "{{#{field}}} is not a declared input") unless @trusted.key?(field)

            need(role != "system" || @trusted.fetch(field), path,
                 "{{#{field}}} is an untrusted input, which a system component cannot hold")
          end
        end
      end
    end
  end
end
