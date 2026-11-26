# frozen_string_literal: true

require_relative "../smith"
require_relative "template"
require_relative "definitions/format"
require_relative "definitions/digests"
require_relative "definitions/validator"
require_relative "definitions/document"

module Smith
  # Definitions as data (additions design 2): an agent or a judge written
  # as a JSON document in Smith's own closed, versioned format (format 1,
  # published as docs/schemas/smith-definition-1.json; shaped like Open
  # Agent Spec, but not a standard), checked and digested:
  #
  #   doc = Smith::Definitions.parse(json_or_hash) # or DefinitionInvalid
  #   doc.digest           # => "sha256:..."
  #   doc.with_llm(provider: "openai", model: "gpt-5") # a model variant
  #
  # Loaded only by `require "smith/definitions"`. Building classes from a
  # document, the catalog that holds them and restores are slice 1d.2's.
  module Definitions
    # A Document from a Hash (String or Symbol keys) or its JSON text, every
    # rule checked. `stored: true` reads back a document Smith accepted
    # before (a host's store, the catalog's restores): every rule but the
    # settings check against the model table, which ran when it was created
    # or imported, so a later Smith that learns a model drops a setting
    # never strands it; the Document says so (`stored?`), so what runs it
    # can check its settings first. `stored` is true or false.
    def self.parse(value, stored: false) = Document.new(value, stored:)
  end
end
