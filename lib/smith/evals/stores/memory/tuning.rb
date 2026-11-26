# frozen_string_literal: true

require_relative "../../store"

module Smith
  module Evals
    module Stores
      class Memory
        # Internal. The memory store's tuning methods (slice 5a; the
        # interface is Smith::Evals::Store's): each checks its record, then
        # keeps it as the store keeps an eval run's.
        module Tuning
          def create_tuning(scope:, header:)
            scope = Store::Records.scope!(scope)
            created(scope, Store::TuningRecords.header!(header, scope), nil)
          end

          def read_tuning_header(scope:, tuning_run_id:) = read(*tuning_ids!(scope, tuning_run_id), &:header)

          def append_tuning_line(scope:, tuning_run_id:, line:, lease:)
            scope, id = tuning_ids!(scope, tuning_run_id)
            append(scope, id, lease, :tuning_line, Store::TuningRecords.line!(line, id))
          end

          def each_tuning_line(scope:, tuning_run_id:, &)
            each_line(:each_tuning_line, :tuning_line, *tuning_ids!(scope, tuning_run_id), &)
          end

          def write_tuning_summary(scope:, tuning_run_id:, summary:, lease:)
            scope, id = tuning_ids!(scope, tuning_run_id)
            summarize(scope, id, lease, Store::TuningRecords.summary!(summary, scope, id))
          end

          def read_tuning_summary(scope:, tuning_run_id:) = read(*tuning_ids!(scope, tuning_run_id), &:summary)

          private

          def tuning_ids!(scope, tuning_run_id)
            [Store::Records.scope!(scope), Store::TuningRecords.tuning_run_id!(tuning_run_id)]
          end
        end
      end
    end
  end
end
