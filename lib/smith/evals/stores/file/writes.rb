# frozen_string_literal: true

require_relative "../../errors"
require_relative "../../store/lease"
require_relative "../../store/tuning_records"
require_relative "documents"
require_relative "lines"

module Smith
  module Evals
    module Stores
      class File
        # Internal. Leases and the writes that need one (slice-1a design,
        # 9.3). A lease is flock(LOCK_EX | LOCK_NB) on the run's `lease` file,
        # held until release or until its process dies, and only one holder
        # writes a run. It belongs to the process that took it: a forked child
        # closes its copy of the lease file (so the parent's release or death
        # frees the run) and may not write under it. Process.daemon does not
        # call the hook, so a holder that daemonizes keeps its lease until the
        # daemon exits. Each write holds the run's Mutex (threads share a
        # lease) and checks the lease it was given is this store's live one.
        # The ids each line file holds are read once per lease, so the same
        # line again is :exists and another line under its id is refused.
        class Writes
          # The run's state in this process.
          State = Struct.new(:mutex, :lease, :held, :pid)
          # Lease files open in this process, closed in a forked child.
          LEASES = ObjectSpace::WeakMap.new

          # Process._fork's hook (Ruby 3.1 and later).
          module Forked
            def _fork
              pid = super
              LEASES.each_key(&:close) if pid.zero?
              pid
            end
          end
          Process.singleton_class.prepend(Forked)

          def initialize(paths)
            @paths = paths
            @states = {}
            @lock = Mutex.new
          end

          # RunBusy while another holder has it; torn tails are cut first.
          def lease(run, scope, id)
            file = @paths.opened(::File.join(run, "lease"), ::File::RDWR | ::File::CREAT)
            LEASES[file] = true # at once, so a fork from another thread closes it too
            free = @paths.io(file.path) { file.flock(::File::LOCK_EX | ::File::LOCK_NB) }
            raise RunBusy, "#{Store::TuningRecords.run_name(id)} #{id} is leased by another holder" unless free

            lease = leased(run, scope, id, file)
          ensure
            file&.close unless lease
          end

          def append(run, id, lease, name, record)
            write(run, id, lease) do |state|
              held = state.held[name] ||= Lines.held(@paths, ::File.join(run, name))
              next :exists if held?(held, record, id)

              appended(state, name, record.key => record.digest) { Lines.append(@paths, run, name, record.text) }
            end
          end

          # Only above the stored revision; the stored summary again is
          # :exists.
          def summarize(run, id, lease, record)
            write(run, id, lease) do
              path = ::File.join(run, "summary.json")
              stored = Documents.read(@paths, path)
              next :exists if stored && Documents.identity(@paths, path, stored) == record.digest

              revision = stored && stored["summary_revision"]
              if revision && !(revision.is_a?(Integer) && record.key > revision)
                raise ArgumentError, "summary_revision #{record.key} is not above the stored #{revision}"
              end

              Documents.replace(@paths, run, path, record.text)
              :written
            end
          end

          private

          # Whether this very line is there; another under its id is refused.
          def held?(held, record, id)
            return false unless held.key?(record.key)
            return true if held[record.key] == record.digest

            raise ArgumentError, "#{Store::TuningRecords.run_name(id)} #{id} already holds a different line " \
                                 "with this id"
          end

          def state(run) = @lock.synchronize { @states[run] ||= State.new(Mutex.new, nil, {}) }

          def leased(run, scope, id, file)
            state = state(run)
            state.mutex.synchronize do
              Lines::FILES.each_value { Lines.cut(@paths, run, _1) }
              @paths.sync_folders(run)
              Documents.sweep(@paths, run)
              state.held = {}
              state.pid = Process.pid
              state.lease = Store::Lease.new(scope:, **Store::TuningRecords.run_key(id)) { released(state, file) }
            end
          end

          def released(state, file)
            state.mutex.synchronize do
              state.lease = nil
              state.held = {}
              file.close
            end
          end

          def write(run, id, lease)
            state = state(run)
            state.mutex.synchronize do
              run = "#{Store::TuningRecords.run_name(id)} #{id}"
              unless lease.is_a?(Store::Lease) && state.lease.equal?(lease) && !lease.released?
                raise ArgumentError, "a write to #{run} needs its live lease from this store"
              end
              raise ArgumentError, "the lease on #{run} belongs to another process" if state.pid != Process.pid

              yield state
            end
          end

          # A write that fails forgets the file's ids, so the next one reads
          # them again from what reached the disk. The ids are added in place:
          # a copy would make each append O(lines).
          def appended(state, name, added)
            held = state.held.delete(name)
            yield
            state.held[name] = held.update(added)
            :appended
          end
        end
        private_constant :Writes
      end
    end
  end
end
