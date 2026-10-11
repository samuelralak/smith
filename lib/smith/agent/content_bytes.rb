# frozen_string_literal: true

module Smith
  class Agent
    # The documents and images of one agent invocation, read from the run's
    # artifacts once, before its first attempt, and checked: readable, a
    # non-empty String, of the kind its media type names (a PDF, PNG, JPEG,
    # GIF or WebP by its leading bytes, `text/plain` as UTF-8), an image at
    # most MAX_IMAGE_BYTES and any part at most Content::MAX_PART_BYTES, and
    # the request's text with its documents and images as they are sent
    # (PDFs and images in base64) at most MAX_REQUEST_BYTES. Anything else
    # raises Smith::ContentUnavailable. Held per thread for the invocation,
    # so parallel branches read their own.
    module ContentBytes
      MAX_IMAGE_BYTES = 5 * 1024 * 1024
      MAX_REQUEST_BYTES = 32 * 1024 * 1024
      SIGNATURES = {
        "application/pdf" => ->(bytes) { bytes.start_with?("%PDF-".b) },
        "image/png" => ->(bytes) { bytes.start_with?("\x89PNG\r\n\x1A\n".b) },
        "image/jpeg" => ->(bytes) { bytes.start_with?("\xFF\xD8\xFF".b) },
        "image/gif" => ->(bytes) { bytes.start_with?("GIF87a".b, "GIF89a".b) },
        "image/webp" => ->(bytes) { bytes.byteslice(0, 4) == "RIFF".b && bytes.byteslice(8, 4) == "WEBP".b },
        "text/plain" => ->(bytes) { bytes.dup.force_encoding(Encoding::UTF_8).valid_encoding? }
      }.freeze
      HELD = :smith_content_bytes
      private_constant :SIGNATURES, :HELD

      module_function

      def with(messages)
        outer = Thread.current[HELD]
        Thread.current[HELD] = read(Array(messages))
        yield
      ensure
        Thread.current[HELD] = outer
      end

      # A part's bytes, as the invocation read them, or read now.
      def fetch(part)
        held = Thread.current[HELD]
        key = [part["artifact"], part["media_type"]]
        held&.key?(key) ? held.fetch(key) : checked_bytes(part)
      end

      def read(messages)
        held = {}
        total = 0
        messages.each do |message|
          next unless Message.parts?(message)

          (message[:content] || message["content"]).map { |part| Content.check!(part) }.each do |part|
            total += sent_bytes(part, held)
            next if total <= MAX_REQUEST_BYTES

            raise ContentUnavailable, "the request's text, documents and images come to more than " \
                                      "#{MAX_REQUEST_BYTES} bytes as sent"
          end
        end
        held.freeze
      end

      def sent_bytes(part, held)
        return part["text"].bytesize if part["type"] == "text"

        bytes = (held[[part["artifact"], part["media_type"]]] ||= checked_bytes(part))
        part["media_type"] == "text/plain" ? bytes.bytesize : 4 * ((bytes.bytesize + 2) / 3)
      end

      def checked_bytes(part)
        bytes = stored_bytes(part)
        limit = part["type"] == "image" ? MAX_IMAGE_BYTES : Content::MAX_PART_BYTES
        problem = if !bytes.is_a?(String) then "is missing or expired, or not a String"
                  elsif bytes.empty? then "is empty"
                  elsif bytes.bytesize > limit then "is larger than #{limit} bytes"
                  elsif !SIGNATURES.fetch(part["media_type"]).call(bytes.b) then "is not #{part["media_type"]}"
                  end
        return bytes unless problem

        raise ContentUnavailable, "the artifact of a #{part["type"]} part #{problem}"
      end

      # Through the run's scoped store, which must be able to tell which run
      # stored a ref.
      def stored_bytes(part)
        store = Smith.scoped_artifacts
        unless store.respond_to?(:vouches?) && store.vouches?
          raise ContentUnavailable, "content parts are read inside a step, from an artifact store that records " \
                                    "which run stored each artifact (stored_by?)"
        end

        store.fetch(part["artifact"])
      rescue ContentUnavailable
        raise
      rescue StandardError => e
        raise ContentUnavailable, "the artifact of a #{part["type"]} part could not be read: " \
                                  "#{DiagnosticText.error_class_name(e)}"
      end
    end
  end
end
