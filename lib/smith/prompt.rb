# frozen_string_literal: true

require_relative "content_identity"
require_relative "errors"
require_relative "template"

module Smith
  # Experimental. A named prompt (plan 5.2): an agent's tunable text with
  # the component id a tuner credits, declared as the agent's instructions:
  #
  #   instructions Smith::Prompt.file("triage.rules", "app/prompts/triage.md")
  #   instructions Smith::Prompt.new("triage.rules", "You sort postings for {{person}}.")
  #
  # The text is inert: never ERB or Ruby, a file read as it is. Its only
  # substitution is Smith::Template's `{{name}}` fields, filled from the
  # agent's inputs. Its version is its text's SHA-256, the rule definition
  # format 1 versions a prompt component by, and a text that replaces it
  # (a candidate, a registry's version) keeps exactly its fields. Frozen;
  # loaded when first named, never by `require "smith"`. O(L) to read a
  # text of L bytes, O(L + V) to fill it in with V bytes of values.
  class Prompt
    attr_reader :component_id, :text, :version, :fields

    def self.file(component_id, path) = new(component_id, File.read(path, mode: "r:UTF-8"))

    def initialize(component_id, text)
      @component_id = component_id!(component_id)
      raise PromptInvalid, "#{@component_id}: a prompt's text is a String, not #{text.class}" unless text.is_a?(String)

      @template = template!(text)
      @text = text.dup.freeze
      @version = ContentIdentity.digest(@text)
      @fields = @template.fields
      freeze
    end

    # The same component with another text, refused unless it keeps
    # exactly these fill-in fields.
    def with_text(text)
      other = Prompt.new(component_id, text)
      return other if other.fields.sort == fields.sort

      raise PromptInvalid, "#{component_id}: a new text keeps the fill-in fields #{named(fields)}; " \
                           "this one has #{named(other.fields)}"
    end

    # The text with its fields filled in from `values`, in one pass.
    def render(values) = @template.render(values)

    private

    def component_id!(value)
      return value.dup.freeze if value.is_a?(String) && ContentIdentity::ID.match?(value)

      raise PromptInvalid, "a prompt's component id is 1 to 128 lowercase letters, digits, \".\", \"_\" or \"-\", " \
                           "from a letter or digit"
    end

    def template!(text)
      Template.new(text)
    rescue ArgumentError => e
      raise PromptInvalid, "#{@component_id}: #{e.message}"
    end

    def named(names) = names.empty? ? "none" : names.sort.map { "{{#{_1}}}" }.join(", ")
  end
end
