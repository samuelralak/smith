# frozen_string_literal: true

require "securerandom"

require_relative "store_rules"

module Smith
  module Artifacts
    # An artifact store in a database table, through the host's Active
    # Record model (a class or its name):
    #
    #   create_table :smith_artifacts do |t|
    #     t.string :ref, null: false, index: { unique: true }
    #     t.binary :data, null: false, limit: 64.megabytes   # MySQL's blob holds 64 KiB
    #     t.string :content_type, null: false
    #     t.string :execution_namespace, index: true
    #     t.timestamps
    #   end
    #
    # Each artifact is one row, its ref a random UUID (after the store's
    # tenant `namespace:` when one is set), with the run that stored it, so
    # the store can say which run stored a ref.
    class ActiveRecordStore
      include StoreRules

      INNER_REF = StoreRules::UUID

      def initialize(model:, namespace: nil)
        @model_source = model.is_a?(String) ? model.dup.freeze : model
        @namespace = check_namespace!(namespace)
      end

      def store(data, content_type: "application/octet-stream", execution_namespace: nil)
        enforce_tenant_isolation!
        check_data!(data)
        ref = generate_ref(SecureRandom.uuid)
        model_class.create!(ref:, data:, content_type:, execution_namespace:)
        ref
      end

      def fetch(ref)
        enforce_tenant_isolation!
        model_class.find_by(ref:)&.data if owns_ref?(ref)
      end

      # Whether a run (its execution namespace) stored this ref.
      def stored_by?(ref, execution_namespace)
        !execution_namespace.nil? && owns_ref?(ref) && model_class.where(ref:, execution_namespace:).exists?
      end

      def model = model_class

      def expired(retention: nil, execution_namespace: nil)
        retention = effective_retention(retention)
        return [] unless retention

        scope = model_class.where(model_class.arel_table[:created_at].lt(Time.now.utc - retention))
        scope = scope.where(execution_namespace:) if execution_namespace
        scope.pluck(:ref).select { |ref| owns_ref?(ref) }
      end

      # Removes the artifact (when a run is named, only if that run stored
      # it).
      def delete(ref, execution_namespace: nil)
        enforce_tenant_isolation!
        return unless owns_ref?(ref)

        scope = model_class.where(ref:)
        scope = scope.where(execution_namespace:) if execution_namespace
        scope.delete_all
        nil
      end

      private

      def model_class = @model_source.is_a?(String) ? Object.const_get(@model_source) : @model_source
    end
  end
end
