# frozen_string_literal: true

require "fileutils"
require_relative "../../errors"

module Smith
  module Evals
    module Stores
      class File
        # Internal. Every folder and file the file store touches, all under
        # its root. Each folder from the root down is checked with lstat (a
        # link is refused, never followed) and each file is opened with
        # O_NOFOLLOW, so no path leaves the root; with O_NONBLOCK and checked
        # to be a regular file before a byte is read, so a FIFO never blocks.
        # Ids are lowercase hex, so on a case-insensitive file system two runs
        # never share a folder. A file with another link is never written, so
        # a hard link cannot carry a write out of the root. Files are 0600 and
        # folders 0700. Checks are lstat then use, so the store trusts whoever
        # can write its root. A flush is F_FULLFSYNC on macOS, whose fsync
        # leaves a write in the drive's cache, and fsync elsewhere. Problems
        # raise StoreError naming the path within the root; the store adds its
        # operation.
        class Paths
          FLAGS = %i[NOFOLLOW NONBLOCK].select { ::File::Constants.const_defined?(_1) }
                                       .map { ::File::Constants.const_get(_1) }.reduce(0, :|)
          LINKED = [Errno::ELOOP, Errno::EMLINK].freeze
          # Opening a FIFO with no reader for writing, or a folder.
          NOT_REGULAR = [Errno::ENXIO, Errno::EISDIR].freeze
          FULL_FLUSH = RUBY_PLATFORM.include?("darwin") ? 51 : nil # F_FULLFSYNC
          # What fcntl says on a file system without a full flush.
          NO_FULL_FLUSH = %i[EINVAL ENOTSUP ENOTTY].filter_map { Errno.const_get(_1) if Errno.const_defined?(_1) }

          attr_reader :root

          def initialize(root)
            @root = root
          end

          def scope_folder(scope) = ::File.join(@root, "v1", "scopes", Smith::Scope.digest(scope))
          def runs_folder(scope) = ::File.join(scope_folder(scope), "runs")
          def run_folder(scope, id) = ::File.join(runs_folder(scope), id)

          # The folder, when it and each folder above it up to the root are
          # folders; nil when one is missing.
          def folder(path)
            below(path).all? { folder?(_1) } ? path : nil
          end

          # Makes each missing folder up to path, then flushes every folder
          # from the root down to path's own, so a name a killed writer made
          # and never flushed is flushed now.
          def folder!(path)
            io(@root) { FileUtils.mkdir_p(@root, mode: 0o700) }
            below(path).each { |part| made?(part) || folder?(part) || raise(failure(part, "could not be made")) }
            sync_folders(::File.dirname(path))
            path
          end

          # Whether a regular file is there; a link or anything else raises.
          def file?(path)
            stat = io(path) { ::File.lstat(path) }
            raise failure(path, "is a link, which the store never makes") if stat.symlink?
            raise failure(path, "is not a regular file") unless stat.file?

            true
          rescue Errno::ENOENT
            false
          end

          # A regular file of the store, opened with the given flags.
          def opened(path, flags, perm = 0o600)
            file = io(path) { ::File.open(path, flags | FLAGS, perm, binmode: true) }
            return file if file.stat.file?

            file.close
            raise failure(path, "is not a regular file")
          end

          # nil when the file is not there.
          def open_read(path)
            opened(path, ::File::RDONLY)
          rescue Errno::ENOENT
            nil
          end

          # A file opened to append, and whether this call made it.
          def appendable(path)
            file, made = begin
              [opened(path, ::File::RDWR | ::File::APPEND), false]
            rescue Errno::ENOENT
              [opened(path, ::File::RDWR | ::File::APPEND | ::File::CREAT | ::File::EXCL), true]
            end
            return [file, made] if file.stat.nlink == 1

            file.close
            raise failure(path, "has another link, which the store never makes")
          end

          # Refuses to replace a file with another link.
          def single_link!(path)
            nlink = io(path) { ::File.lstat(path).nlink }
            raise failure(path, "has another link, which the store never makes") if nlink > 1
          rescue Errno::ENOENT
            nil
          end

          # Flushes to the drive, by fsync where there is no full flush.
          def sync(file, path)
            io(path) do
              FULL_FLUSH ? file.fcntl(FULL_FLUSH) : file.fsync
            rescue *NO_FULL_FLUSH
              file.fsync
            end
          end

          def sync_folder(path)
            io(path) { ::File.open(path, ::File::RDONLY) { sync(_1, path) } }
          end

          # The root and each folder below it down to path.
          def sync_folders(path) = [@root, *below(path)].each { sync_folder(_1) }

          def relative(path) = path.delete_prefix("#{@root}/")

          def failure(path, problem) = StoreError.new("#{relative(path)} #{problem}", operation: nil)

          # Runs an I/O call, turning its failure into StoreError, except a
          # missing file and an existing name, which callers read.
          def io(path)
            yield
          rescue Errno::ENOENT, Errno::EEXIST
            raise
          rescue *LINKED
            raise failure(path, "is a link, which the store never makes")
          rescue *NOT_REGULAR
            raise failure(path, "is not a regular file")
          rescue SystemCallError, IOError => e
            raise failure(path, "cannot be used (#{e.class.name})")
          end

          private

          def made?(path)
            io(path) { Dir.mkdir(path, 0o700) }
            true
          rescue Errno::EEXIST
            false
          end

          # The folders from just below the root down to path.
          def below(path)
            parts = relative(path).split("/")
            parts.each_index.map { ::File.join(@root, *parts[0.._1]) }
          end

          def folder?(path)
            stat = io(path) { ::File.lstat(path) }
            raise failure(path, "is a link, which the store never makes") if stat.symlink?
            raise failure(path, "is not a folder") unless stat.directory?

            true
          rescue Errno::ENOENT
            false
          end
        end
        private_constant :Paths
      end
    end
  end
end
