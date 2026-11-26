# frozen_string_literal: true

require_relative "../../errors"
require_relative "../../store/records"
require_relative "../../store/tuning_records"
require_relative "../../store/listing"
require_relative "documents"
require_relative "lines"

module Smith
  module Evals
    module Stores
      class File
        # Internal. Finding and reading a scope's runs, eval runs and tuning
        # runs: the folders, the header that makes a folder a record, its
        # documents and lines, and the listing's entries (eval runs only).
        class Runs
          def initialize(paths)
            @paths = paths
          end

          # The run's folder, or nil.
          def folder(scope, id) = @paths.folder(@paths.run_folder(scope, id))

          # The run's folder when its header is there.
          def recorded!(scope, id)
            run = folder(scope, id)
            return run if run && @paths.file?(::File.join(run, "header.json"))

            raise ArgumentError, "no #{Store::TuningRecords.run_name(id)} #{id} in this scope"
          end

          # Makes the run's folders. scope.json is written with the scope's
          # first record and must name this scope ever after.
          def made!(scope, id)
            run = ::File.dirname(@paths.folder!(::File.join(@paths.run_folder(scope, id), "tmp")))
            target = ::File.join(@paths.scope_folder(scope), "scope.json")
            return run if !@paths.file?(target) &&
                          Documents.create(@paths, run, target, Store::Records.document_text(scope)) == :created
            return run if Documents.read(@paths, target) == scope

            raise @paths.failure(target, "names another scope")
          end

          def document(scope, id, name)
            run = folder(scope, id)
            run && Documents.read(@paths, ::File.join(run, name))
          end

          def lines(scope, id, name)
            run = folder(scope, id)
            Lines.each(@paths, ::File.join(run, name)) { |value, _text| yield value } if run
          end

          # Every header in the scope as a listing entry, without its status,
          # and the runs whose header does not read, as unreadable entries.
          def entries(scope)
            runs = @paths.folder(@paths.runs_folder(scope))
            return [[], []] unless runs

            listed = @paths.io(runs) { Dir.children(runs) }.grep(Store::Records::EVAL_RUN_ID).filter_map do |id|
              header = document(scope, id, "header.json")
              header && entry(scope, id, header)
            rescue RecordCorrupt, StoreError => e
              Store::Listing.unreadable(id, e.message)
            end
            listed.partition { !_1.key?("problem") }
          end

          # The run's status, "running" without a summary, or an unreadable
          # entry when its summary does not read by the rules it was written by.
          def status(scope, id)
            summary = document(scope, id, "summary.json") or return "running"
            Store::Records.summary_fields!(summary, scope, id)
            summary["status"]
          rescue RecordCorrupt, StoreError => e
            Store::Listing.unreadable(id, e.message)
          rescue ArgumentError => e
            unreadable(scope, id, "summary.json", e)
          end

          private

          # A header read by the rules it was written by, in its own folder.
          def entry(scope, id, header)
            raise ArgumentError, "the header names another run" if Store::Records.header_fields!(header, scope) != id

            Store::Listing.entry(header)
          rescue ArgumentError => e
            unreadable(scope, id, "header.json", e)
          end

          def unreadable(scope, id, name, error)
            path = @paths.relative(::File.join(@paths.run_folder(scope, id), name))
            Store::Listing.unreadable(id, "#{path}: #{error.message}")
          end
        end
        private_constant :Runs
      end
    end
  end
end
