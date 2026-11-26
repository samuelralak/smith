# frozen_string_literal: true

require_relative "../../errors"
require_relative "../../store/tuning_records"
require_relative "documents"

module Smith
  module Evals
    module Stores
      class File
        # Internal. The append-only line files, segments.jsonl and
        # trials.jsonl (slice-1a design, 9.4), and a tuning run's lines.jsonl.
        # An append is one line and its line feed, written whole and flushed
        # before it returns; the folder too when the file is new. A crash can
        # leave only a last line without its line feed: readers skip it, and
        # the next writer cuts it before appending. A cut replaces the file
        # with its complete lines (written, flushed, renamed over it), never
        # truncating in place, so a reader already reading keeps the old file
        # and never meets a line made of two. A read takes no lock and yields
        # the lines there when it began, never one appended during it.
        # O(line) to append, O(file) to read or cut.
        module Lines
          MAX_BYTES = Store::Records::MAX_BYTES
          FILES = { segment: "segments.jsonl", trial: "trials.jsonl", tuning_line: "lines.jsonl" }.freeze
          CHUNK = 65_536

          module_function

          def append(paths, run, name, text)
            cut(paths, run, name)
            path = ::File.join(run, name)
            file, made = paths.appendable(path)
            write(paths, file, path, "#{text}\n")
            paths.sync_folder(run) if made
          end

          # Each complete line's record, text and number, in order, up to the
          # file's size when the read began. A last line without its line feed
          # is a write still going or torn by a crash, and ends the reading. A
          # complete line that does not read raises RecordCorrupt with its
          # number.
          def each(paths, path)
            file = paths.open_read(path) or return
            begin
              left = paths.io(path) { file.size }
              (1..).each do |number|
                chunk = next_line(paths, file, path, left) or break
                left -= chunk.bytesize
                yield(*parsed(paths, path, chunk, number), number)
              end
            ensure
              file.close
            end
          end

          # The next line within the left bytes, read MAX_BYTES and a byte at
          # most; nil at the end or at a last line without its line feed. A
          # line past the bound is given whole for parsed to refuse.
          def next_line(paths, file, path, left)
            chunk = left.positive? && paths.io(path) { file.gets("\n", [MAX_BYTES + 1, left].min) }
            chunk if chunk && (chunk.end_with?("\n") || chunk.bytesize > MAX_BYTES)
          end

          # Cuts a torn last line, replacing the file with what comes before
          # it.
          def cut(paths, run, name)
            path = ::File.join(run, name)
            file = paths.open_read(path) or return
            begin
              keep = torn_at(paths, file, path)
              return unless keep

              paths.single_link!(path)
              temporary = Documents.temporary(paths, run, name) do |copy|
                paths.io(path) { IO.copy_stream(file, copy, keep, 0) }
              end
              paths.io(path) { ::File.rename(temporary, path) }
              paths.sync_folder(run)
            ensure
              file.close
            end
          end

          # The ids already in a line file, each with its record's identity,
          # so a line written again is known and another under its id is
          # refused.
          def held(paths, path)
            ids = {}
            each(paths, path) { |value, _text, number| ids[id_of(value)] = identity(paths, path, value, number) }
            ids
          end

          def identity(paths, path, value, number)
            Store::JSONCheck.identity(value)
          rescue ArgumentError => e
            raise corrupt(paths, path, number, e.message)
          end

          # A trial line's trial id and revision, a tuning line's type and
          # iteration, or a launch line's number.
          def id_of(value)
            case value["format"]
            when Store::Records::FORMATS[:trial] then value.values_at("trial_id", "trial_revision")
            when Store::TuningRecords::FORMATS[:line] then value.values_at("type", "iteration")
            else value["segment"]
            end
          end

          # Where the complete lines end when the last line is torn; nil when
          # the file ends at a line feed.
          def torn_at(paths, file, path)
            size = paths.io(path) { file.size }
            return if size.zero? || paths.io(path) { file.pread(1, size - 1) } == "\n"

            last_line_end(paths, file, path, size)
          end

          def last_line_end(paths, file, path, size)
            while size.positive?
              start = [size - CHUNK, 0].max
              found = paths.io(path) { file.pread(size - start, start) }.rindex("\n")
              return start + found + 1 if found

              size = start
            end
            0
          end

          def write(paths, file, path, line)
            Documents.write_all(paths, file, line)
            paths.sync(file, path)
          ensure
            file.close
          end

          def parsed(paths, path, chunk, number)
            text = chunk.end_with?("\n") ? chunk.byteslice(0, chunk.bytesize - 1) : chunk
            text.force_encoding(Encoding::UTF_8)
            raise corrupt(paths, path, number, "is longer than #{MAX_BYTES} bytes") if text.bytesize > MAX_BYTES
            raise corrupt(paths, path, number, "is not UTF-8") unless text.valid_encoding?

            [Store::Records.read(text), text]
          rescue ArgumentError => e
            raise corrupt(paths, path, number, e.message)
          end

          def corrupt(paths, path, number, problem)
            RecordCorrupt.new("#{paths.relative(path)} line #{number}: #{problem}", line: number)
          end
        end
        private_constant :Lines
      end
    end
  end
end
