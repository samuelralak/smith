# frozen_string_literal: true

module Smith
  module Definitions
    class Validator
      # A document's inputs: JSON Schema properties with a title (the
      # fill-in field's name) and a type, and Smith's trust and fence.
      class InputsCheck
        include Checks

        def initialize(problems)
          @problems = problems
        end

        # Each input's name, and whether it is trusted (untrusted unless it
        # says so), as far as the inputs can be read; nil when they are not
        # a list.
        def trusted(inputs)
          return unless list!(inputs, "/inputs")

          @trusted = {}
          inputs.each_with_index { |input, index| input!(input, "/inputs/#{index}") }
          @trusted.freeze
        end

        private

        def input!(input, path)
          return unless object!(input, path)

          fields!(input, path, INPUT_FIELDS, "a field of an input")
          required(input, "title", path) { title!(_1, input, "#{path}/title") }
          required(input, "type", path) do |type|
            need(INPUT_TYPES.include?(type), "#{path}/type", "is #{INPUT_TYPES[0..-2].join(", ")} or array")
          end
          need(text?(input["description"]), "#{path}/description", "is a non-empty String") if input.key?("description")
          trust!(input, path)
        end

        # A reserved or repeated name is refused, but still counts as
        # declared, so its fields are not refused again.
        def title!(title, input, path)
          return problem(path, FIELD_RULE) unless title.is_a?(String) && FIELD_NAME.match?(title)
          return problem(path, "#{title} is declared twice") if @trusted.key?(title)

          need(!RESERVED_INPUTS.include?(title), path, "#{title} is reserved (#{RESERVED_INPUTS.join(", ")})")
          @trusted[title] = input["trust"] == "trusted"
        end

        # Fencing (Smith::Untrusted.wrap) marks untrusted text; a trusted
        # input is never fenced, so it does not say.
        def trust!(input, path)
          need(TRUST.include?(input["trust"]), "#{path}/trust", "is trusted or untrusted") if input.key?("trust")
          return unless input.key?("fence")
          return problem("#{path}/fence", "is true or false") unless boolean?(input["fence"])

          need(input["trust"] != "trusted", "#{path}/fence", "fences only an untrusted input")
        end
      end
    end
  end
end
