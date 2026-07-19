# frozen_string_literal: true

require "dry-initializer"

module Smith
  module Budget
    class LedgerPublication
      extend Dry::Initializer

      option :state
      option :reservations, default: proc { {} }

      private :reservations

      def reservation(token)
        reservations[token]
      end

      def add(next_state, token:, amounts:)
        publish(
          next_state,
          commit: -> { reservations[token] = amounts },
          rollback: -> { reservations.delete(token) }
        )
      end

      def remove(next_state, token:, amounts:)
        publish(
          next_state,
          commit: -> { reservations.delete(token) },
          rollback: -> { reservations[token] = amounts }
        )
      end

      private

      def publish(next_state, commit:, rollback:)
        previous_state = state
        published = false
        begin
          Thread.handle_interrupt(Object => :never) do
            @state = next_state
            published = true
            commit.call
          end
        rescue Exception # rubocop:disable Lint/RescueException
          rollback(previous_state, rollback) if published
          raise
        end
      end

      def rollback(previous_state, operation)
        Thread.handle_interrupt(Object => :never) do
          @state = previous_state
          operation.call
        end
      end
    end
  end
end
