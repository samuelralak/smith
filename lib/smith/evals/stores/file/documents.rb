# frozen_string_literal: true

require "securerandom"
require_relative "../../errors"
require_relative "../../store/records"

module Smith
  module Evals
    module Stores
      class File
        # Internal. Files written whole (slice-1a design, 9.4): a temporary
        # in the run's tmp folder is written and flushed, then linked to its
        # name (a create: EEXIST means it was there, so it is never clobbered)
        # or renamed over it (a replace), and the folder is flushed. A reader
        # sees no file or a whole one. A temporary a crash left behind is
        # removed by the next create or lease of its run once it is an hour
        # old by the system clock, which stamps a local file's times (a
        # store's own clock may run ahead and sweep a write in flight).
        module Documents
          STRAY_AFTER = 3600
          TEMPORARY = /\A[a-z]+\.[0-9a-f]{16}\.jsonl?\z/
          # What link(2) says on a file system without hard links.
          NO_LINKS = %i[EOPNOTSUPP ENOTSUP].filter_map { Errno.const_get(_1) if Errno.const_defined?(_1) }.uniq

          module_function

          # :created, or :exists when the name was taken.
          def create(paths, run, target, text)
            temporary = temporary(paths, run, ::File.basename(target)) { write_all(paths, _1, text) }
            begin
              paths.io(target) { linked(paths, temporary, target) }
            rescue Errno::EEXIST
              return :exists
            ensure
              discard(temporary)
            end
            paths.sync_folder(::File.dirname(target))
            :created
          end

          def replace(paths, run, target, text)
            paths.single_link!(target)
            temporary = temporary(paths, run, ::File.basename(target)) { write_all(paths, _1, text) }
            begin
              paths.io(target) { ::File.rename(temporary, target) }
            rescue StandardError
              discard(temporary)
              raise
            end
            paths.sync_folder(::File.dirname(target))
          end

          # The file's text, or nil when it is not there.
          def text(paths, path)
            file = paths.open_read(path) or return
            begin
              if file.size > Store::Records::MAX_BYTES
                raise corrupt(paths, path, "is over #{Store::Records::MAX_BYTES} bytes")
              end

              text = paths.io(path) { file.read }.force_encoding(Encoding::UTF_8)
              text.valid_encoding? ? text : raise(corrupt(paths, path, "is not UTF-8"))
            ensure
              file.close
            end
          end

          # EPERM may also be a protected folder or an immutable flag.
          def linked(paths, temporary, target)
            ::File.link(temporary, target)
          rescue Errno::EPERM
            raise StoreError.new("#{paths.relative(target)} cannot be linked (Errno::EPERM): the file store needs " \
                                 "a local file system with hard links, and folders and files it may change",
                                 operation: nil)
          rescue *NO_LINKS
            raise StoreError.new("the file store needs a local file system with hard links", operation: nil)
          end

          # A stored record's identity; RecordCorrupt when it has none.
          def identity(paths, path, value)
            Store::JSONCheck.identity(value)
          rescue ArgumentError => e
            raise corrupt(paths, path, e.message)
          end

          # The file's record, or nil; RecordCorrupt when it does not read.
          def read(paths, path, stored = text(paths, path))
            stored && Store::Records.read(stored)
          rescue ArgumentError => e
            raise corrupt(paths, path, e.message)
          end

          # A temporary in the run's tmp folder, written by the block, synced
          # and closed; its path. Removed again when anything fails. A tmp
          # folder removed by hand is made again.
          def temporary(paths, run, name)
            path = ::File.join(run, "tmp", name.sub(".", ".#{SecureRandom.hex(8)}."))
            paths.folder(::File.dirname(path)) || paths.folder!(::File.dirname(path))
            file = paths.opened(path, ::File::WRONLY | ::File::CREAT | ::File::EXCL)
            begin
              yield file
              paths.sync(file, path)
            ensure
              file.close
            end
            written = path
          ensure
            discard(path) unless written
          end

          # Writes every byte, however many calls it takes.
          def write_all(paths, file, text)
            rest = text
            until rest.empty?
              written = paths.io(file.path) { file.syswrite(rest) }
              rest = rest.byteslice(written..)
            end
          end

          def discard(path)
            ::File.unlink(path)
          rescue Errno::ENOENT
            nil
          end

          # Removes the run's temporaries an hour older than the system clock;
          # a tmp folder that is gone holds none.
          def sweep(paths, run)
            now = Time.now
            folder = paths.folder(::File.join(run, "tmp")) or return
            paths.io(folder) { Dir.children(folder) }.grep(TEMPORARY).each do |name|
              path = ::File.join(folder, name)
              stat = paths.io(path) { ::File.lstat(path) }
              discard(path) if stat.file? && stat.mtime < now - STRAY_AFTER
            rescue Errno::ENOENT
              next
            end
          end

          def corrupt(paths, path, problem) = RecordCorrupt.new("#{paths.relative(path)}: #{problem}", line: nil)
        end
        private_constant :Documents
      end
    end
  end
end
