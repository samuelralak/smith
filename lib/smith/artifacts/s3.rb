# frozen_string_literal: true

require "securerandom"

module Smith
  module Artifacts
    # An artifact store in an S3-compatible bucket: AWS S3, Cloudflare R2
    # (`endpoint: "https://<account>.r2.cloudflarestorage.com"`,
    # `region: "auto"`), MinIO and the like. Each artifact is one object
    # under `prefix`, its ref a random UUID (after the store's tenant
    # `namespace:` when one is set), and the run that stored it is kept in
    # the object's metadata, so the store can say which run stored a ref.
    #
    # The client is the host's `Aws::S3::Client` (`client:`), or one built
    # from the remaining options (`region:`, `endpoint:`,
    # `access_key_id:`, `secret_access_key:`, ...), which needs the
    # `aws-sdk-s3` gem in the host's bundle; Smith does not depend on it.
    class S3
      REF = /\A(?:[A-Za-z0-9_-]+:)?[A-Za-z0-9-]+\z/
      NAMESPACE_KEY = "smith-execution-namespace"

      def initialize(bucket:, prefix: "smith/artifacts", namespace: nil, client: nil, **)
        @bucket = bucket
        @prefix = prefix.to_s.delete_suffix("/")
        @namespace = namespace
        @client = client || self.class.build_client(**)
      end

      def self.build_client(**)
        require "aws-sdk-s3"
        ::Aws::S3::Client.new(**)
      rescue LoadError
        raise Smith::Error, "Smith::Artifacts::S3 needs the aws-sdk-s3 gem in the host's bundle, or a client:"
      end

      def store(data, content_type: "application/octet-stream", execution_namespace: nil)
        ref = generate_ref
        metadata = execution_namespace ? { NAMESPACE_KEY => execution_namespace } : {}
        @client.put_object(bucket: @bucket, key: object_key(ref), body: data, content_type:, metadata:)
        ref
      end

      def fetch(ref)
        return unless owns_ref?(ref)

        @client.get_object(bucket: @bucket, key: object_key(ref)).body.read
      rescue StandardError => e
        raise unless missing?(e)
      end

      # Whether a run (its execution namespace) stored this ref.
      def stored_by?(ref, execution_namespace)
        return false unless owns_ref?(ref)

        @client.head_object(bucket: @bucket, key: object_key(ref)).metadata[NAMESPACE_KEY] == execution_namespace
      rescue StandardError => e
        raise unless missing?(e)

        false
      end

      def expired(retention: nil, execution_namespace: nil)
        return [] unless retention

        cutoff = Time.now.utc - retention
        objects.filter_map do |object|
          ref = object.key.delete_prefix("#{@prefix}/")
          next unless object.last_modified.utc < cutoff && owns_ref?(ref)
          next if execution_namespace && !stored_by?(ref, execution_namespace)

          ref
        end
      end

      def delete(ref)
        @client.delete_object(bucket: @bucket, key: object_key(ref)) if owns_ref?(ref)
        nil
      end

      private

      def generate_ref
        raw = SecureRandom.uuid
        @namespace ? "#{@namespace}:#{raw}" : raw
      end

      def object_key(ref) = "#{@prefix}/#{ref}"

      def owns_ref?(ref)
        return false unless ref.is_a?(String) && REF.match?(ref)

        @namespace ? ref.start_with?("#{@namespace}:") : !ref.include?(":")
      end

      # Every object under the prefix, page by page.
      def objects
        Enumerator.new do |yielder|
          token = nil
          loop do
            page = @client.list_objects_v2(bucket: @bucket, prefix: "#{@prefix}/", continuation_token: token)
            page.contents.each { |object| yielder << object }
            break unless page.is_truncated

            token = page.next_continuation_token
          end
        end
      end

      # The SDK's missing-object errors (NoSuchKey on a read, NotFound on a
      # head), by name, so Smith loads no SDK class.
      def missing?(error) = error.class.name.to_s.end_with?("::NoSuchKey", "::NotFound")
    end
  end
end
