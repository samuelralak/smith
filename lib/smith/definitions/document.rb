# frozen_string_literal: true

require_relative "digests"
require_relative "validator"

module Smith
  module Definitions
    # A definition document (additions design 2.4), checked against its
    # format and frozen: the document as written, in its JSON form (String
    # keys, annotations kept), with its digests and each prompt component's
    # fill-in fields. Made by Smith::Definitions.parse, and by
    # replace_component and with_llm, each of which checks the new document
    # whole, its settings against the model table included. Nothing is
    # filled in that the document does not say. Two Documents are the same
    # definition when their digests are equal (annotations aside); `==` is
    # identity, as for any object.
    class Document
      attr_reader :kind, :id, :digest, :prompt_digest, :component_versions

      def initialize(value, stored: false)
        raise ArgumentError, "stored is true or false" unless [true, false].include?(stored)

        @stored = stored
        @document, @templates = Validator.new(value, stored:).result
        body = Digests.body(@document)
        @kind = @document.fetch("kind")
        @id = @document.fetch("id")
        @digest = Digests.document(body)
        @prompt_digest = Digests.prompt(body)
        @component_versions = versions
        freeze
      end

      # Whether it was read back with `stored: true`, its settings left
      # unchecked against today's model table; never so for a document
      # replace_component or with_llm makes. Not in to_h or any digest.
      def stored? = @stored

      # The fill-in fields of a prompt component, by its component_id.
      def placeholders(component_id) = Set.new(template(component_id).fields).freeze

      # A new document with one component's text replaced; refused unless
      # its fill-in fields are the ones the text had (plan 5.2).
      def replace_component(component_id, text)
        fields = placeholders(component_id)
        index = @document.fetch("prompt").index { _1.fetch("component_id") == component_id }
        replaced = Document.new(with_text(index, text))
        return replaced if replaced.placeholders(component_id) == fields

        raise DefinitionInvalid, ["/prompt/#{index}/text: a new text keeps the fill-in fields #{named(fields)}; " \
                                  "this one has #{named(replaced.placeholders(component_id))}"]
      end

      # A model variant: a new document with only its llm changed (settings
      # and fallbacks written out, even when empty), so its prompt digest
      # and component versions stay; its settings are checked for that model.
      def with_llm(provider:, model:, settings: {}, fallbacks: [])
        llm = { "provider" => provider, "model" => model, "settings" => settings, "fallbacks" => fallbacks }
        Document.new(@document.merge("llm" => llm))
      end

      # The document, for a host's store and for export.
      def to_h = @document

      private

      def versions
        @document.fetch("prompt").to_h do |component|
          [component.fetch("component_id"), Digests.text(component.fetch("text"))]
        end.freeze
      end

      def with_text(index, text)
        prompt = @document.fetch("prompt").dup
        prompt[index] = prompt[index].merge("text" => text)
        @document.merge("prompt" => prompt)
      end

      def template(component_id)
        @templates.fetch(component_id) { raise KeyError, "no prompt component #{component_id}" }
      end

      def named(fields) = fields.empty? ? "none" : fields.map { "{{#{_1}}}" }.join(", ")
    end
  end
end
