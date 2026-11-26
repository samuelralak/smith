# frozen_string_literal: true

require "securerandom"
require_relative "errors"
require_relative "../json_value"
require_relative "dataset_manifest"

module Smith
  module Evals
    # Experimental. The folder source (slice-1a design, 4.2): manifest.json
    # beside samples.jsonl (one sample per line), read as UTF-8 bytes
    # whatever the locale. It answers the host source interface
    # (`manifest(scope:)`, `each_sample(scope:)`); a folder has no tenants,
    # so it takes any scope and ignores it. Messages name a line by its
    # number, never by its content. Lines are split at LF (a CR before it
    # is dropped), and blank ones skipped. Only regular files are read: a
    # link that resolves outside the folder, a FIFO or a device is refused
    # without blocking. O(B) time in the bytes read; a line is at most
    # MAX_LINE_BYTES before its line end, the manifest at most
    # MAX_MANIFEST_BYTES.
    class FileDataset
      MANIFEST = "manifest.json"
      MAX_LINE_BYTES = 4 * 1024 * 1024
      MAX_MANIFEST_BYTES = 512 * 1024 * 1024
      # JSON's whitespace only: String#strip would also take NUL.
      BLANK = /\A[ \t\r\n]*\z/
      # O_NONBLOCK keeps opening a FIFO from waiting for a writer; O_NOFOLLOW
      # refuses a link put in place after the path was resolved.
      READ_FLAGS = %i[RDONLY NONBLOCK NOFOLLOW].select { File::Constants.const_defined?(_1) }
                                               .map { File::Constants.const_get(_1) }.reduce(0, :|)

      attr_reader :path

      # samples_file: the file to read; by default the one the manifest
      # names (samples.jsonl when there is no manifest yet).
      def initialize(path, samples_file: nil)
        unless (path.is_a?(String) || path.respond_to?(:to_path)) && !path.to_s.empty?
          raise ArgumentError, "a dataset folder is a path"
        end

        @path = path.to_s.dup.freeze
        @samples_file = samples_file
      end

      # Whether anything is at manifest.json (reading it checks what).
      def manifest? = File.exist?(manifest_path) || File.symlink?(manifest_path)

      # The manifest Hash, parsed; DatasetInvalid when it is missing or is
      # not JSON (its format is checked by DatasetManifest.from_h).
      def manifest(**)
        raise DatasetInvalid, "no #{MANIFEST} in #{path}" unless manifest?

        JSONValue.parse!(manifest_text)
      rescue ArgumentError => e
        raise DatasetInvalid, "#{MANIFEST}: #{e.message}"
      end

      def each_sample(scope: nil, &)
        return enum_for(:each_sample, scope:) unless block_given?

        each_placed_sample { |line, _where| yield line }
      end

      # Each line's JSON with its place ("samples.jsonl line 12").
      def each_placed_sample
        return enum_for(:each_placed_sample) unless block_given?

        name = samples_file
        each_chunk(name) do |chunk, number|
          where = "#{name} line #{number}"
          text = line_text(chunk, where)
          yield parsed(text, where), where unless BLANK.match?(text)
        end
      end

      # Replaces manifest.json whole: written beside it, then renamed.
      def write_manifest(text)
        temporary = File.join(path, ".#{MANIFEST}.#{Process.pid}.#{SecureRandom.hex(4)}")
        File.binwrite(temporary, text)
        File.rename(temporary, manifest_path)
      ensure
        File.delete(temporary) if temporary && File.exist?(temporary)
      end

      private

      def manifest_path = File.join(path, MANIFEST)

      def manifest_text
        opened(MANIFEST) do |file|
          raise DatasetInvalid, "#{MANIFEST} is over #{MAX_MANIFEST_BYTES} bytes" if file.size > MAX_MANIFEST_BYTES

          text = file.read.force_encoding(Encoding::UTF_8)
          text.valid_encoding? ? text : raise(DatasetInvalid, "#{MANIFEST}: not UTF-8")
        end
      end

      # Each line as bytes, at most MAX_LINE_BYTES and its CR LF, with its
      # number from 1. The block is forwarded outside any block of this
      # method's own, which Ruby 3.3.0 cannot parse.
      def each_chunk(name, &)
        file = open_file(name)
        begin
          file.each_line("\n", MAX_LINE_BYTES + 2).with_index(1, &)
        ensure
          file.close
        end
      end

      def opened(name)
        file = open_file(name)
        yield file
      ensure
        file&.close
      end

      # A file of the folder, opened for reading once it is known to be a
      # regular file inside the folder.
      def open_file(name)
        real = File.realpath(File.join(path, name))
        root = File.realpath(path)
        unless real.start_with?(root.end_with?("/") ? root : "#{root}/")
          raise DatasetInvalid, "#{name} is a link outside the dataset's folder"
        end

        regular(File.open(real, READ_FLAGS, binmode: true), name)
      rescue SystemCallError => e
        raise DatasetInvalid, "#{name} cannot be read (#{e.class.name})"
      end

      def regular(file, name)
        return file if file.stat.file?

        raise DatasetInvalid, "#{name} is not a regular file"
      rescue StandardError
        file.close
        raise
      end

      # The file the manifest names is checked before it is opened: a file
      # name in the folder, with no control character in it.
      def samples_file
        return @samples_file if @samples_file
        return DatasetManifest::SAMPLES_FILE unless manifest?

        named = manifest["samples_file"]
        return named if named.is_a?(String) && DatasetManifest::Format::FILE_NAME.match?(named)

        raise DatasetInvalid, "#{MANIFEST}: /samples_file: is a file name in the dataset's folder"
      end

      # The line without its LF or CR LF, as UTF-8.
      def line_text(chunk, where)
        text = chunk.chomp
        raise DatasetInvalid, "#{where}: longer than #{MAX_LINE_BYTES} bytes" if text.bytesize > MAX_LINE_BYTES

        text.force_encoding(Encoding::UTF_8)
        text.valid_encoding? ? text : raise(DatasetInvalid, "#{where}: not UTF-8")
      end

      def parsed(text, where)
        JSONValue.parse!(text)
      rescue ArgumentError => e
        raise DatasetInvalid, "#{where}: #{e.message}"
      end
    end
  end
end
