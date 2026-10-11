# frozen_string_literal: true

require "fileutils"
require "json"
require "securerandom"

require_relative "store_rules"

module Smith
  module Artifacts
    # An artifact store in a directory (`dir:`), shared only when the
    # directory is. Each artifact is a file named by a random UUID (after
    # the store's tenant `namespace:` when one is set) beside a `.meta`
    # file with its type and the run that stored it; no ref names any other
    # file.
    class File
      include StoreRules

      INNER_REF = StoreRules::UUID

      def initialize(dir:, namespace: nil)
        @dir = dir
        @namespace = check_namespace!(namespace)
      end

      def store(data, content_type: "application/octet-stream", execution_namespace: nil)
        enforce_tenant_isolation!
        check_data!(data)
        ref = generate_ref(SecureRandom.uuid)
        meta = { content_type: content_type }
        meta[:execution_namespace] = execution_namespace if execution_namespace
        ::File.binwrite(::File.join(@dir, ref), data)
        ::File.write(::File.join(@dir, "#{ref}.meta"), JSON.generate(meta))
        ref
      end

      def fetch(ref)
        enforce_tenant_isolation!
        return unless owns_ref?(ref)

        path = ::File.join(@dir, ref)
        ::File.binread(path) if ::File.file?(path)
      end

      # Removes the artifact (when a run is named, only if that run stored
      # it).
      def delete(ref, execution_namespace: nil)
        enforce_tenant_isolation!
        return unless owns_ref?(ref) && (execution_namespace.nil? || stored_by?(ref, execution_namespace))

        [ref, "#{ref}.meta"].each { |name| ::FileUtils.rm_f(::File.join(@dir, name)) }
        nil
      end

      # Whether a run (its execution namespace) stored this ref.
      def stored_by?(ref, execution_namespace)
        !execution_namespace.nil? && owns_ref?(ref) && stored_namespace(ref) == execution_namespace
      end

      def expired(retention: nil, execution_namespace: nil)
        retention = effective_retention(retention)
        return [] unless retention

        cutoff = Time.now.utc - retention
        Dir.glob(::File.join(@dir, "*")).filter_map do |path|
          ref = ::File.basename(path)
          next unless owns_ref?(ref) && ::File.mtime(path).utc < cutoff
          next if execution_namespace && stored_namespace(ref) != execution_namespace

          ref
        end
      end

      private

      def stored_namespace(ref)
        meta_path = ::File.join(@dir, "#{ref}.meta")
        return unless ::File.exist?(meta_path)

        JSON.parse(::File.read(meta_path))["execution_namespace"]
      rescue JSON::ParserError
        nil
      end
    end
  end
end
