# frozen_string_literal: true

require_relative "format"
require_relative "validator/checks"
require_relative "validator/json_form"
require_relative "validator/inputs_check"
require_relative "validator/llm_check"
require_relative "validator/outputs_check"
require_relative "validator/prompt_check"

module Smith
  module Definitions
    # Internal. Checks a document against definition format 1: first its
    # JSON form (JSONForm), then the format, field by field in the format's
    # order, collecting every "path: problem" line. O(N) in the document's
    # values, each bounded (Format), plus the template and schema checks.
    class Validator
      include Checks

      # `stored`: the document was written by Smith before, so settings are
      # not checked against today's model table (they were when it was
      # created or imported).
      def initialize(value, stored: false)
        @stored = stored
        @problems = []
        @document = JSONForm.new(@problems).read(value)
        check if @problems.empty?
      end

      # The document in its JSON form, deeply frozen, and its prompt
      # components' templates by id; DefinitionInvalid when it breaks a rule.
      def result
        raise DefinitionInvalid, @problems unless @problems.empty?

        [@document, @templates]
      end

      private

      def check
        return unless header?

        fields!(@document, "", FIELDS.fetch(@kind), "a field of #{judge? ? "a judge" : "an agent"}")
        identity
        sections
        annotations!(@document, "")
      end

      def judge? = @kind == "judge"

      def section(key, &) = required(@document, key, "", &)

      # The format and the kind, which every other rule depends on.
      def header?
        known = section("smith_definition") do |format|
          need(format.is_a?(Integer) && FORMATS.include?(format), "/smith_definition",
               "is a format Smith builds: #{FORMATS.join(", ")}")
        end
        @kind = known && section("kind") { |kind| need(FIELDS.key?(kind), "/kind", KIND_RULE) && kind }
        !@kind.nil?
      end

      def identity
        section("id") { need(_1.is_a?(String) && ID.match?(_1), "/id", ID_RULE) }
        %w[name description].each do |key|
          need(text?(@document[key]), "/#{key}", "is a non-empty String") if @document.key?(key)
        end
        section("version") { need(integer?(_1, 1), "/version", "is an Integer from 1 to #{MAX_INTEGER}") } if judge?
      end

      def sections
        trusted = section("inputs") { InputsCheck.new(@problems).trusted(_1) }
        section("llm") { LlmCheck.new(@problems, models: !@stored).check(_1) }
        OutputsCheck.new(@problems).check(@document["outputs"]) if !judge? && @document.key?("outputs")
        @templates = section("prompt") { PromptCheck.new(@problems, trusted).templates(_1) } || {}
      end
    end
    private_constant :Validator
  end
end
