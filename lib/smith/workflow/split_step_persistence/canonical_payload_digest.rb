# frozen_string_literal: true

require "digest"
require "dry-initializer"
require "json"

module Smith
  class Workflow
    module SplitStepPersistence
      class CanonicalPayloadDigest
        extend Dry::Initializer

        MAX_BYTES = 4 * 1024 * 1024
        MAX_NODES = 100_000

        param :payload

        def self.call(payload) = new(payload).call

        def call
          if payload.bytesize > MAX_BYTES
            raise WorkflowError, "split-step preparation payload exceeds maximum bytes #{MAX_BYTES}"
          end

          @nodes = 0
          canonical = canonicalize(JSON.parse(payload))
          Digest::SHA256.hexdigest(JSON.generate(canonical))
        end

        private

        def canonicalize(value)
          visit!
          case value
          when Hash then canonical_hash(value)
          when Array then value.map { |item| canonicalize(item) }
          when Float then value == value.to_i ? value.to_i : value
          else value
          end
        end

        def canonical_hash(value)
          value.keys.sort.to_h { |key| [key, canonicalize(value.fetch(key))] }
        end

        def visit!
          @nodes += 1
          return if @nodes <= MAX_NODES

          raise WorkflowError, "split-step preparation payload exceeds maximum size #{MAX_NODES}"
        end
      end
    end
  end
end
