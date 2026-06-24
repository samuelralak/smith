# frozen_string_literal: true

module Smith
  class Workflow
    # ActiveRecord-aware atomic claim helper. Two strategies:
    #
    # .atomic — AASM-event path. SELECT FOR UPDATE + record.public_send(transition_via)
    #           inside transaction_owner.transaction. AASM callbacks fire.
    # .cas    — single-statement CAS via update_all + where(status: from_statuses).
    #           Does NOT invoke AASM events; intended for non-AASM claim sites
    #           that already use update_all today.
    #
    # ActiveRecord is loaded lazily — this file does NOT const-reference
    # ::ActiveRecord at module load. Both methods raise AdapterUnavailable
    # before any other work when ::ActiveRecord is not defined.
    module Claim
      class AdapterUnavailable < Smith::Error; end
      class UnexpectedStatus < Smith::Error
        attr_reader :model, :id, :observed_status

        def initialize(model:, id:, observed_status:)
          @model = model
          @id = id
          @observed_status = observed_status
          super("unexpected status #{observed_status.inspect} for #{model.name}##{id}")
        end
      end

      def self.atomic(model_class, id:, from_statuses:, transition_via:,
                      terminal_statuses: [], on_unexpected_status: :raise,
                      transaction_owner: nil)
        ensure_active_record!
        validate_atomic_args!(model_class, transition_via)

        owner = transaction_owner || model_class
        from = Array(from_statuses).map(&:to_s)
        terminal = Array(terminal_statuses).map(&:to_s)

        claimed = false

        owner.transaction do
          locked = model_class.lock.find(id)
          status = locked.public_send(:status).to_s

          if from.include?(status)
            locked.public_send(transition_via)
            claimed = true
          elsif terminal.include?(status)
            claimed = false
          else
            handle_unexpected_status!(model_class, id, status, on_unexpected_status)
            claimed = false
          end
        end

        claimed ? model_class.find(id) : nil
      end

      def self.cas(model_class, id:, from_statuses:, to_status:,
                   status_column: :status, updated_at_column: :updated_at,
                   now: -> { Time.now.utc })
        ensure_active_record!
        from = Array(from_statuses).map(&:to_s)

        updates = { status_column => to_status.to_s }
        updates[updated_at_column] = now.call if updated_at_column

        rows = model_class
          .where(:id => id, status_column => from)
          .update_all(updates)

        rows.zero? ? nil : model_class.find(id)
      end

      def self.ensure_active_record!
        return if defined?(::ActiveRecord::Base)

        raise AdapterUnavailable,
              "Smith::Workflow::Claim requires ActiveRecord (::ActiveRecord::Base is not defined). " \
              "Add activerecord to your bundle. See docs/workflow_claim.md."
      end
      private_class_method :ensure_active_record!

      def self.validate_atomic_args!(model_class, transition_via)
        if transition_via.nil?
          if model_class.respond_to?(:aasm)
            raise ArgumentError,
                  "Smith::Workflow::Claim.atomic requires transition_via: when the model uses AASM " \
                  "(#{model_class.name} responds to .aasm). Use .cas for non-AASM CAS claims."
          end
          raise ArgumentError, "Smith::Workflow::Claim.atomic requires transition_via: (Symbol naming the event method)"
        end

        return if transition_via.is_a?(Symbol) || transition_via.is_a?(String)

        raise ArgumentError, "transition_via must be a Symbol or String; got #{transition_via.inspect}"
      end
      private_class_method :validate_atomic_args!

      def self.handle_unexpected_status!(model_class, id, status, mode)
        case mode
        when :raise
          raise UnexpectedStatus.new(model: model_class, id: id, observed_status: status)
        when :ignore
          nil
        when :log
          Smith.config.logger&.warn(
            "Smith::Workflow::Claim.atomic: unexpected status #{status.inspect} for #{model_class.name}##{id}"
          )
          nil
        else
          raise ArgumentError, "on_unexpected_status must be :raise, :ignore, or :log; got #{mode.inspect}"
        end
      end
      private_class_method :handle_unexpected_status!
    end
  end
end
