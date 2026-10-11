# frozen_string_literal: true

require "fileutils"
require "json"
require "securerandom"

module Smith
  module Artifacts
    class File
      # A ref names a file in the store's directory and nothing else.
      REF = /\A(?:[A-Za-z0-9_-]+:)?[A-Za-z0-9-]+\z/

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
        return nil unless owns_ref?(ref)

        path = ::File.join(@dir, ref)
        ::File.file?(path) ? ::File.read(path) : nil
      end

      def delete(ref)
        return unless owns_ref?(ref)

        [ref, "#{ref}.meta"].each { |name| ::FileUtils.rm_f(::File.join(@dir, name)) }
        nil
      end

      # Whether a run (its execution namespace) stored this ref.
      def stored_by?(ref, execution_namespace)
        owns_ref?(ref) && matches_execution_namespace?(ref, execution_namespace)
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

      def owns_ref?(ref)
        return false unless ref.is_a?(String) && REF.match?(ref)

        @namespace ? ref.start_with?("#{@namespace}:") : !ref.include?(":")
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
