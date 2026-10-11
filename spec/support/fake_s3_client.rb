# frozen_string_literal: true

require "stringio"

# An in-memory stand-in for Aws::S3::Client as the SDK behaves: user metadata
# keys come back lowercased, bodies are binary, listings page two objects at
# a time with a nil token on the last page, and a missing object raises
# Aws::S3::Errors::NoSuchKey or ::NotFound (stub them).
class FakeS3Client
  StoredObject = Struct.new(:body, :content_type, :metadata, :last_modified)
  Listed = Struct.new(:key, :last_modified)
  Page = Struct.new(:contents, :is_truncated, :next_continuation_token)

  attr_reader :objects

  def initialize = @objects = {}

  def put_object(bucket:, key:, body:, content_type:, metadata:)
    @objects[[bucket, key]] =
      StoredObject.new(body.b, content_type, metadata.transform_keys { _1.to_s.downcase }, Time.now.utc)
    nil
  end

  def get_object(bucket:, key:) = Struct.new(:body).new(StringIO.new(found(bucket, key, :NoSuchKey).body))

  def head_object(bucket:, key:) = Struct.new(:metadata).new(found(bucket, key, :NotFound).metadata)

  def delete_object(bucket:, key:) = @objects.delete([bucket, key]) && nil

  def head_bucket(bucket:) = { bucket: }

  def list_objects_v2(bucket:, prefix:, continuation_token: nil)
    keys = listed_keys(bucket, prefix)
    start = continuation_token.to_i
    listed = (keys[start, 2] || []).map { Listed.new(_1, @objects[[bucket, _1]].last_modified) }
    truncated = start + 2 < keys.length
    Page.new(listed, truncated, truncated ? (start + 2).to_s : nil)
  end

  private

  def listed_keys(bucket, prefix)
    @objects.keys.select { |(name, key)| name == bucket && key.start_with?(prefix) }.map(&:last).sort
  end

  def found(bucket, key, missing) = @objects[[bucket, key]] || raise(Aws::S3::Errors.const_get(missing), key)
end
