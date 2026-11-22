# frozen_string_literal: true

require "digest"
require_relative "canonical_json"
require_relative "error"

module Smith
  # A value that is not a Smith::Scope. The message names the problem, never
  # a scope value.
  class ScopeInvalid < Error; end

  # The one tenant scope type: a frozen Hash of at most 8 pairs, String keys
  # such as "tenant" (a lowercase letter, then lowercase letters, digits or
  # "_", at most 64 in all) and String values of 1 to 256 bytes of UTF-8.
  # Eval runs, eval stores, definition references and run credential scopes
  # all use it, so a tenant is named one way everywhere. Pure, and not loaded
  # by `require "smith"`.
  #
  #   scope = Smith::Scope.build(tenant: "ten_0193", project: "prj_7")
  #   # => {"project" => "prj_7", "tenant" => "ten_0193"} (frozen)
  #   Smith::Scope.digest(scope) # => 32 lowercase hex digits
  #
  # Symbol keys are converted; anything else raises ScopeInvalid. O(p log p)
  # for p pairs (at most 8).
  module Scope
    MAX_PAIRS = 8
    KEY = /\A[a-z][a-z0-9_]{0,63}\z/
    VALUE_BYTES = (1..256)
    DIGEST_FRAME = "smith.evals.scope/1\n"

    class << self
      # The scope as a frozen Hash of frozen Strings, keys in order.
      def build(value)
        raise ScopeInvalid, "a scope is a Hash, not #{value.class}" unless value.is_a?(Hash)
        raise ScopeInvalid, "a scope holds at most #{MAX_PAIRS} pairs, not #{value.size}" if value.size > MAX_PAIRS

        named_pairs(value).sort_by(&:first).to_h { |key, text| [key, value_text(key, text)] }.freeze
      end

      # The scope digest: the first 32 hex digits of SHA-256 of
      # "smith.evals.scope/1\n" and the scope's canonical JSON, the same in
      # any process and any language.
      def digest(value)
        Digest::SHA256.hexdigest(DIGEST_FRAME + CanonicalJSON.generate(build(value)))[0, 32]
      end

      private

      # Symbol keys converted; two keys that convert to one name raise.
      def named_pairs(value)
        pairs = value.map { |key, text| [key_name(key), text] }
        pairs.map(&:first).tally.each do |key, count|
          raise ScopeInvalid, "scope key #{key.inspect} is given twice" if count > 1
        end
        pairs
      end

      def key_name(key)
        name = key.is_a?(Symbol) ? key.name : key
        unless name.is_a?(String) && name.valid_encoding? && name.match?(KEY)
          raise ScopeInvalid, "scope keys are Strings such as \"tenant\" (#{KEY.source}), not #{shown(key)}"
        end

        frozen_utf8(name)
      end

      def value_text(key, text)
        unless text.is_a?(String) && VALUE_BYTES.cover?(text.bytesize) && utf8?(text)
          raise ScopeInvalid, "scope value for #{key.inspect} must be a String of 1 to 256 bytes of UTF-8"
        end

        frozen_utf8(text)
      end

      def frozen_utf8(text)
        return text if text.frozen? && text.encoding == Encoding::UTF_8

        text.dup.force_encoding(Encoding::UTF_8).freeze
      end

      def utf8?(text)
        (text.encoding == Encoding::UTF_8 && text.valid_encoding?) || text.ascii_only?
      end

      # A bad key named without echoing much of it.
      def shown(key)
        key.is_a?(String) || key.is_a?(Symbol) ? key.to_s[0, 64].inspect : "a #{key.class}"
      end
    end
  end
end
