# frozen_string_literal: true

require_relative "../canonical_json"
require_relative "../error"

module Smith
  # A document that is not a definition Smith builds. `problems` lists every
  # "path: problem" line found, at most MAX_PROBLEMS, each path a JSON
  # Pointer into the document ("/" for the whole of it). A line names
  # fields, positions, limits, and the model, component id or fill-in field
  # at fault, never another value the document holds. A key or one of those
  # names longer than 64 characters is shown by its first 64 and its length
  # ("kkk…(9000 characters)"), so a path holding such a key reads as one
  # but no longer resolves in the document.
  class DefinitionInvalid < Error
    MAX_PROBLEMS = 100

    attr_reader :problems

    def initialize(problems)
      @problems = Array(problems).first(MAX_PROBLEMS).map { |line| String(line).dup.freeze }.freeze
      super("the definition is invalid: #{@problems.join("; ")}")
    end
  end

  module Definitions
    # The definition formats this Smith builds. A new field means a new
    # format; every format shipped stays buildable within a major version.
    # `kind` is reserved: a later Smith adds kinds within format 1 (the
    # workflow, slice 3c), and a reader refuses a kind it does not know.
    FORMATS = [1].freeze

    # Internal. Format 1's names and bounds (additions design 2.3), each
    # checked as it is reached, so reading a document is bounded.
    module Format
      MAX_BYTES = 1024 * 1024
      MAX_DEPTH = 32
      MAX_VALUES = 20_000
      MAX_TEXT_BYTES = 64 * 1024
      MAX_FIELDS = 200
      MAX_SCHEMA_LEVELS = 10
      MAX_INTEGER = CanonicalJSON::MAX_SAFE_INTEGER

      KIND_RULE = "is not a kind this Smith reads; it reads agent and judge"
      ID = /\A[a-z0-9][a-z0-9._-]{0,127}\z/
      ID_RULE = 'is 1 to 128 lowercase letters, digits, ".", "_" or "-", starting with a letter or digit'
      FIELD_NAME = /\A[A-Za-z_][A-Za-z0-9_]{0,63}\z/
      FIELD_RULE = 'is a fill-in field name: a letter or "_", then up to 63 letters, digits or "_"'
      MODEL = /\A[^\u0000-\u001f\u007f]{1,256}\z/
      MODEL_RULE = "is a model id: 1 to 256 characters, none of them a control character"

      COMMON = %w[smith_definition kind id name description inputs].freeze
      FIELDS = { "agent" => [*COMMON, "outputs", "llm", "prompt", "annotations"],
                 "judge" => [*COMMON.take(3), "version", *COMMON.drop(3), "llm", "prompt", "annotations"] }
               .transform_values(&:freeze).freeze
      INPUT_FIELDS = %w[title type description trust fence].freeze
      INPUT_TYPES = %w[string number integer boolean object array].freeze
      # The agent runtime and the credential hook read chat, prompt and
      # context; Smith reserves the rest for every agent
      # (Agent::RESERVED_INPUT_NAMES).
      RESERVED_INPUTS = %w[chat prompt context model_id provider endpoint_mode].freeze
      TRUST = %w[trusted untrusted].freeze
      LLM_FIELDS = %w[provider model settings fallbacks assume_exists].freeze
      SETTINGS = %w[temperature max_output_tokens thinking].freeze
      THINKING = %w[effort budget].freeze
      EFFORTS = %w[low medium high].freeze
      FALLBACK_FIELDS = %w[provider model].freeze
      COMPONENT_FIELDS = %w[component_id role text annotations].freeze
      ROLES = %w[system user].freeze
      # A key holding one of these words, its case and separators ignored,
      # is taken for a credential, which a definition never carries.
      SECRET = /apikey|token|secret|password|authorization|credential/
    end
    private_constant :Format
  end
end
