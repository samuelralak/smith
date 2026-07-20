# frozen_string_literal: true

require "digest"
require "dry-initializer"
require "json"

require_relative "../message_value_normalizer"

module Smith
  class Workflow
    module Composite
      class PayloadDigest
        extend Dry::Initializer

        param :value

        def self.call(value) = new(value).call

        def call
          normalized = MessageValueNormalizer.new(value, label: "composite payload").call
          Digest::SHA256.hexdigest(JSON.generate(normalized))
        end
      end

      private_constant :PayloadDigest
    end
  end
end
