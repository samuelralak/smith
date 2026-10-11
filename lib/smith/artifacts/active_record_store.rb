# frozen_string_literal: true

require "securerandom"

module Smith
  module Artifacts
    # An artifact store in a database table, through the host's Active
    # Record model (a class or its name):
    #
    #   create_table :smith_artifacts do |t|
    #     t.string :ref, null: false, index: { unique: true }
    #     t.binary :data, null: false
    #     t.string :content_type, null: false
    #     t.string :execution_namespace, index: true
    #     t.timestamps
    #   end
    #
    # Each artifact is one row, its ref a random UUID (after the store's
    # tenant `namespace:` when one is set), with the run that stored it, so
    # the store can say which run stored a ref.
    class ActiveRecordStore
      REF = /\A(?:[A-Za-z0-9_-]+:)?[A-Za-z0-9-]+\z/

      def initialize(model:, namespace: nil)
        @model_source = model.is_a?(String) ? model.dup.freeze : model
        @namespace = namespace
      end

      def store(data, content_type: "application/octet-stream", execution_namespace: nil)
        ref = generate_ref
        model_class.create!(ref:, data:, content_type:, execution_namespace:)
        ref
      end

      def fetch(ref)
        model_class.find_by(ref:)&.data if owns_ref?(ref)
      end

      # Whether a run (its execution namespace) stored this ref.
      def stored_by?(ref, execution_namespace)
        owns_ref?(ref) && model_class.where(ref:, execution_namespace:).exists?
      end

      def expired(retention: nil, execution_namespace: nil)
        return [] unless retention

        scope = model_class.where(model_class.arel_table[:created_at].lt(Time.now.utc - retention))
        scope = scope.where(execution_namespace:) if execution_namespace
        scope.pluck(:ref).select { |ref| owns_ref?(ref) }
      end

      def delete(ref)
        model_class.where(ref:).delete_all if owns_ref?(ref)
        nil
      end

      private

      def model_class = @model_source.is_a?(String) ? Object.const_get(@model_source) : @model_source

      def generate_ref
        raw = SecureRandom.uuid
        @namespace ? "#{@namespace}:#{raw}" : raw
      end

      def owns_ref?(ref)
        return false unless ref.is_a?(String) && REF.match?(ref)

        @namespace ? ref.start_with?("#{@namespace}:") : !ref.include?(":")
      end
    end
  end
end
