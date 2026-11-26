# frozen_string_literal: true

require_relative "../canonical_json"
require_relative "../content_identity"

module Smith
  module Definitions
    # Internal. The digests of definition format 1 (additions design 2.9),
    # the convention slice 1a's identity uses: "sha256:" and 64 lowercase
    # hex of a "name/N\n" frame and RFC 8785 canonical JSON, or of a single
    # text's UTF-8 bytes, frozen, so no caller can change an identity it
    # was given. Each takes a document in its JSON form (String keys) and
    # is O(N + sum k_i log k_i) in its values and keys, plus hashing; pure,
    # so any language computes the same.
    module Digests
      module_function

      # The document as every digest takes it: without its annotations, the
      # object at the top and on each prompt component, which a host keeps
      # and Smith never reads.
      def body(document)
        prompt = document.fetch("prompt").map { |component| component.except("annotations") }
        document.except("annotations").merge("prompt" => prompt)
      end

      def document(body) = framed("smith.definition/#{body.fetch("smith_definition")}", body)

      # Equal prompt digests: two documents differ at most in their llm.
      def prompt(body) = framed("smith.definition_prompt/#{body.fetch("smith_definition")}", body.except("llm"))

      # An agent component's execution identity; for an agent or a judge
      # document the component is the document.
      def agent(component) = framed("smith.definition_agent/1", component)

      # A built workflow class's definition digest: the document's, with a
      # host's base identity only when it gives one. Never Smith's execution
      # semantics version, so a saved run restores across a Smith release.
      def workflow(document_digest, base_identity: nil)
        value = { "document" => document_digest }
        unless base_identity.nil?
          raise ArgumentError, "a base identity is a String" unless base_identity.is_a?(String)

          value["base_identity"] = base_identity
        end
        framed("smith.definition_workflow/1", value)
      end

      # A prompt component's version: its text's UTF-8 bytes.
      def text(text) = ContentIdentity.digest(text)

      def framed(frame, value) = text("#{frame}\n#{CanonicalJSON.generate(value)}")
    end
    private_constant :Digests
  end
end
