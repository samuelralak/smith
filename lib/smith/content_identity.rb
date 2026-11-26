# frozen_string_literal: true

require "digest"

module Smith
  # Internal. The id and digest rules that definitions, the prompt seam and
  # evals share, kept here once: definition format 1's id (a document's or
  # a prompt component's), and a content digest, "sha256:" and the 64
  # lowercase hex of the SHA-256 of a text's bytes (a prompt component's
  # version, and every digest definitions and evals frame). Pure, and not
  # loaded by `require "smith"`.
  module ContentIdentity
    ID = /\A[a-z0-9][a-z0-9._-]{0,127}\z/
    DIGEST = /\Asha256:[0-9a-f]{64}\z/

    module_function

    def digest(text) = "sha256:#{Digest::SHA256.hexdigest(text)}".freeze
  end
  private_constant :ContentIdentity
end
