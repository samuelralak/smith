# frozen_string_literal: true

module Smith
  module Evals
    module Store
      # Experimental. One holder's right to write an eval run, from
      # `acquire_lease` until `release` (idempotent, from any thread). A
      # store takes writes only under the lease it handed out, so a released
      # lease writes nothing. The file store's lease is also freed by the
      # operating system when its process dies. A host's store may hand out
      # any object that answers `release`.
      class Lease
        attr_reader :scope, :eval_run_id, :tuning_run_id

        # The run's id by its kind (Records.run_key): an eval run's, or a
        # tuning run's (slice 5a). The block runs once, on the first release.
        def initialize(scope:, eval_run_id: nil, tuning_run_id: nil, &on_release)
          @scope = scope
          @eval_run_id = eval_run_id
          @tuning_run_id = tuning_run_id
          @on_release = on_release
          @lock = Mutex.new
          @released = false
        end

        def release
          callback = @lock.synchronize do
            next if @released

            @released = true
            @on_release
          end
          callback&.call
          nil
        end

        def released? = @lock.synchronize { @released }
      end
    end
  end
end
