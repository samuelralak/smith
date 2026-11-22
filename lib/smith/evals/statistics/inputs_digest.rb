# frozen_string_literal: true

require "digest"

module Smith
  module Evals
    module Statistics
      # The inputs digest (design 7.2): SHA-256 of "smith.evals.stats/1\n"
      # and the canonical JSON {"data", "function", "options"}, streamed a
      # sample at a time, so its memory is one sample's, not the data's.
      # O(B) for B canonical bytes.
      module InputsDigest
        FRAME = "smith.evals.stats/1\n"

        class << self
          def call(function, options, data)
            sha = Digest::SHA256.new
            sha << FRAME << '{"data":'
            stream(sha, data)
            sha << ',"function":' << CanonicalJSON.generate(function)
            sha << ',"options":' << CanonicalJSON.generate(options) << "}"
            "sha256:#{sha.hexdigest}"
          end

          private

          def stream(sha, data)
            case data
            when Hash then stream_object(sha, data)
            when Array then stream_array(sha, data)
            when Sample then sha << CanonicalJSON.generate(data.to_h)
            else sha << CanonicalJSON.generate(data)
            end
          end

          def stream_object(sha, data)
            sha << "{"
            data.keys.sort_by { |key| SampleList.utf16(key) }.each_with_index do |key, index|
              sha << "," unless index.zero?
              sha << CanonicalJSON.generate(key) << ":"
              stream(sha, data[key])
            end
            sha << "}"
          end

          def stream_array(sha, data)
            sha << "["
            data.each_with_index do |item, index|
              sha << "," unless index.zero?
              stream(sha, item)
            end
            sha << "]"
          end
        end
      end
      private_constant :InputsDigest
    end
  end
end
