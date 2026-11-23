# frozen_string_literal: true

require "json"
require "uri"
require_relative "billing_refusals"
require_relative "diagnostic_text"
require_relative "errors"
require_relative "interruptions"
require_relative "provider_errors"
require_relative "provider_options"

module Smith
  # Removes a run's credential values from text (additions design 3.6): any
  # run of WINDOW bytes copied from a value, which no ordinary text holds by
  # chance, wherever it occurs, as written or as JSON or a URL escapes it (an
  # AWS secret key's "/" echoed as "\/" or "%2F" would break it into runs
  # shorter than a window). Every value is LONG bytes or more: a shorter
  # secret could not be told apart from ordinary text, and is refused where
  # credentials are built (ProviderOptions::Checks), never scrubbed loosely.
  # A base64 form of a value is not looked for. Shorter fragments (a key
  # masked to its first eight and last four characters) are what Smith's
  # fixed texts for refused keys cover.
  #
  # Values are compared as bytes. Their windows are built once, O(V) for V
  # bytes of values and escaped forms; a text of M bytes is scrubbed in
  # O(M). Immutable: `with` adds values.
  class ProviderCredentialsScrubber
    WINDOW = 12
    LONG = 16
    REDACTED = "[REDACTED]"
    # Smith's own words for a refused key, credit or model, in place of a
    # provider's, which may echo part of the key.
    FIXED = {
      key_refused: "the provider refused the run's key (HTTP 401)",
      out_of_credit: "the provider reports the account is out of credit (HTTP 402)",
      permission: "the provider refused the run's key access to this model (HTTP 403)"
    }.freeze

    def initialize(values)
      values = values.map { _1.to_s.b }.uniq
      raise ArgumentError, "a scrubbed value must be #{LONG} bytes or more" if values.any? { _1.bytesize < LONG }

      @values = values.freeze
      @windows = windows(values)
      freeze
    end

    def with(values) = self.class.new(@values + values.map { _1.to_s.b })

    def empty? = @values.empty?

    def holds?(text) = !spans(text.to_s.b).empty?

    # The text with every value and window replaced by REDACTED, in the
    # text's own encoding.
    def scrub(text)
      text = text.to_s
      bytes = text.b
      merged(spans(bytes)).reverse_each { |from, to| bytes[from...to] = REDACTED }
      bytes.force_encoding(text.encoding).then { _1.valid_encoding? ? _1 : _1.scrub }
    end

    # The error as Smith takes it in a credentialed attempt, before anything
    # else reads it. A provider's error, classified first where its body is
    # read (ProviderErrors, BillingRefusals), becomes a copy of that class
    # (ProviderOptions.copy) whose message and body are scrubbed, or are
    # FIXED for a refused key, credit or model, with no cause. Any other
    # error whose message, or one in its cause chain, holds part of a value
    # becomes a ScrubbedError naming its class, with no cause; anything else
    # is returned as it is.
    def scrubbed(error)
      return copied(error) if ProviderOptions.provider_error?(error)
      return error unless held?(error)

      text = DiagnosticText.capture(scrub(said(error)), max_bytes: 1024)
      ScrubbedError.new("#{DiagnosticText.error_class_name(error)}: #{text}", original_class: error.class.name)
                   .tap { _1.set_backtrace(error.backtrace) if error.backtrace }
    end

    def inspect = "#<#{self.class.name}>"
    alias to_s inspect

    private

    def copied(error)
      classified = BillingRefusals.classified(ProviderErrors.classified(error))
      fixed = FIXED[ProviderOptions.refusal_kind(classified)]
      response = classified.response
      ProviderOptions.copy(classified, status: (response.status if response.respond_to?(:status)),
                                       body: fixed || scrubbed_value(response.respond_to?(:body) && response.body),
                                       message: fixed || scrub(classified.message))
    end

    def scrubbed_value(value)
      case value
      when Hash then value.to_h { |key, nested| [scrubbed_value(key), scrubbed_value(nested)] }
      when Array then value.map { scrubbed_value(_1) }
      when String then scrub(value)
      when nil, false then nil
      else value
      end
    end

    # Whether the error, or one of its causes, holds part of a value in its
    # message or how it prints. One that cannot be read is taken to.
    def held?(error)
      return false if empty?

      current = error
      Interruptions::CAUSE_DEPTH.times do
        return false unless current.is_a?(Exception)
        return true if holds?(current.message) || holds?(current.inspect)

        current = current.cause
      end
      false
    rescue StandardError
      true
    end

    def said(error)
      error.message.to_s
    rescue StandardError
      ""
    end

    # Every WINDOW-byte run of each value, written or escaped.
    def windows(values)
      values.flat_map { escaped(_1) }.uniq
            .flat_map { |value| (0..(value.bytesize - WINDOW)).map { value.byteslice(_1, WINDOW) } }
            .to_set.freeze
    end

    # A value as written, and as JSON or a URL may carry it.
    def escaped(value)
      text = value.dup.force_encoding(Encoding::UTF_8)
      return [value] unless text.valid_encoding?

      json = JSON.generate(text)[1...-1]
      url = URI.encode_www_form_component(text)
      [value, json, json.gsub("/", "\\/"), url, url.gsub(/%\h\h/, &:downcase)].map(&:b).uniq
    end

    # [from, to) byte ranges of every window the bytes hold; a value's whole
    # occurrence is the windows it is made of, merged.
    def spans(bytes)
      return [] if @windows.empty?

      (0..(bytes.bytesize - WINDOW)).filter_map do |at|
        [at, at + WINDOW] if @windows.include?(bytes.byteslice(at, WINDOW))
      end
    end

    def merged(spans)
      spans.sort.each_with_object([]) do |(from, to), kept|
        if kept.any? && from <= kept.last[1]
          kept.last[1] = [kept.last[1], to].max
        else
          kept << [from, to]
        end
      end
    end
  end
end
