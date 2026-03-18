# frozen_string_literal: true

require "securerandom"
require "json"

module Smith
  module Artifacts
    class File
      def initialize(dir:, namespace: nil)
        @dir = dir
        @namespace = namespace
      end

      def store(data, content_type: "application/octet-stream")
        ref = generate_ref
        ::File.write(::File.join(@dir, ref), data)
        ::File.write(::File.join(@dir, "#{ref}.meta"), JSON.generate(content_type: content_type))
        ref
      end

      def fetch(ref)
        path = ::File.join(@dir, ref)
        ::File.exist?(path) ? ::File.read(path) : nil
      end

      def expired(retention: nil)
        return [] unless retention

        cutoff = Time.now.utc - retention
        Dir.glob(::File.join(@dir, "*")).reject { |f| f.end_with?(".meta") }.filter_map do |path|
          ref = ::File.basename(path)
          ref if ::File.mtime(path).utc < cutoff
        end
      end

      private

      def generate_ref
        raw = SecureRandom.uuid
        @namespace ? "#{@namespace}:#{raw}" : raw
      end
    end
  end
end
