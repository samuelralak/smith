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

      def store(data, content_type: "application/octet-stream", execution_namespace: nil)
        ref = generate_ref
        meta = { content_type: content_type }
        meta[:execution_namespace] = execution_namespace if execution_namespace
        ::File.write(::File.join(@dir, ref), data)
        ::File.write(::File.join(@dir, "#{ref}.meta"), JSON.generate(meta))
        ref
      end

      def fetch(ref)
        path = ::File.join(@dir, ref)
        ::File.exist?(path) ? ::File.read(path) : nil
      end

      def expired(retention: nil, execution_namespace: nil)
        return [] unless retention

        cutoff = Time.now.utc - retention
        Dir.glob(::File.join(@dir, "*")).reject { |f| f.end_with?(".meta") }.filter_map do |path|
          ref = ::File.basename(path)
          next unless ::File.mtime(path).utc < cutoff
          next if execution_namespace && !matches_execution_namespace?(ref, execution_namespace)

          ref
        end
      end

      private

      def generate_ref
        raw = SecureRandom.uuid
        @namespace ? "#{@namespace}:#{raw}" : raw
      end

      def matches_execution_namespace?(ref, execution_namespace)
        meta_path = ::File.join(@dir, "#{ref}.meta")
        return false unless ::File.exist?(meta_path)

        meta = JSON.parse(::File.read(meta_path), symbolize_names: true)
        meta[:execution_namespace] == execution_namespace
      rescue JSON::ParserError
        false
      end
    end
  end
end
