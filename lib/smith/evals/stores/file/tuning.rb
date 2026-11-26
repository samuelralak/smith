# frozen_string_literal: true

require_relative "../../store"

module Smith
  module Evals
    module Stores
      class File
        # Internal. The file store's tuning methods (slice 5a; the interface
        # is Smith::Evals::Store's): each checks its record, then keeps it in
        # the tuning run's folder as the store keeps an eval run's.
        module Tuning
          def create_tuning(scope:, header:)
            scope = Store::Records.scope!(scope)
            create(:create_tuning, scope, Store::TuningRecords.header!(header, scope))
          end

          def read_tuning_header(scope:, tuning_run_id:)
            document(:read_tuning_header, *tuning_ids!(scope, tuning_run_id), "header.json")
          end

          def append_tuning_line(scope:, tuning_run_id:, line:, lease:)
            scope, id = tuning_ids!(scope, tuning_run_id)
            append(:append_tuning_line, scope, id, lease, Store::TuningRecords.line!(line, id))
          end

          def each_tuning_line(scope:, tuning_run_id:, &)
            each_line(:each_tuning_line, :tuning_line, *tuning_ids!(scope, tuning_run_id), &)
          end

          def write_tuning_summary(scope:, tuning_run_id:, summary:, lease:)
            scope, id = tuning_ids!(scope, tuning_run_id)
            summarize(:write_tuning_summary, scope, id, lease, Store::TuningRecords.summary!(summary, scope, id))
          end

          def read_tuning_summary(scope:, tuning_run_id:)
            document(:read_tuning_summary, *tuning_ids!(scope, tuning_run_id), "summary.json")
          end

          private

          def tuning_ids!(scope, tuning_run_id)
            [Store::Records.scope!(scope), Store::TuningRecords.tuning_run_id!(tuning_run_id)]
          end
        end
      end
    end
  end
end
