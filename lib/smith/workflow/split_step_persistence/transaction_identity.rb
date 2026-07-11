# frozen_string_literal: true

require "dry-initializer"

module Smith
  class Workflow
    module SplitStepPersistence
      class TransactionIdentity
        extend Dry::Initializer

        param :adapter

        def self.capture(adapter) = new(adapter).capture
        def self.matches?(adapter, expected) = new(adapter).matches?(expected)

        def capture
          return unless PersistenceAdapters.supports?(adapter, :transaction_open?)
          return unless adapter.transaction_open?

          ensure_identity_capability!
          identity = adapter.transaction_identity
          if !identity || identity.to_s.empty?
            raise WorkflowError, "transactional split-step persistence requires an active transaction identity"
          end

          identity.to_s.dup.freeze
        end

        def matches?(expected)
          capture == expected
        rescue StandardError
          false
        end

        private

        def ensure_identity_capability!
          return if PersistenceAdapters.supports?(adapter, :transaction_identity)

          raise WorkflowError, "transactional split-step persistence requires transaction_identity"
        end
      end
    end
  end
end
