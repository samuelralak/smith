# frozen_string_literal: true

require "json"
require "uri"
require "smith/provider_credentials_scrubber"

# Removing a run's credential values from text (additions design 3.6): any
# run of 12 characters copied from a value, every value being 16 or more,
# wherever it occurs, as written or JSON- or URL-escaped.
RSpec.describe Smith::ProviderCredentialsScrubber do
  let(:key) { "sk-canary-#{"0f1e2d3c4b5a6978" * 2}" }
  let(:scrubber) { described_class.new([key]) }

  it "removes every whole value, wherever it occurs, however often" do
    text = "key #{key}, again #{key}; and #{key}"

    expect(scrubber.scrub(text)).to eq("key [REDACTED], again [REDACTED]; and [REDACTED]")
    expect(scrubber.holds?(text)).to be(true)
  end

  it "refuses a value shorter than 16 bytes, which it could not tell apart from ordinary text" do
    expect { described_class.new(["password1"]) }.to raise_error(ArgumentError, /16 bytes/)
    expect { scrubber.with(["short-1"]) }.to raise_error(ArgumentError, /16 bytes/)
  end

  # A secret with "/" or "+" (an AWS secret key, a PEM body) echoed as JSON
  # escapes it ("\/") or as a URL does ("%2F") breaks into runs shorter than
  # a window. A base64 form of a secret is not matched.
  it "removes a value JSON-escaped or URL-encoded, as an echo may carry it" do
    secret = "wJalrXUtnFEMI/K7MDENG/bPxRfiCY+EXAMPLE/KEY="
    scrubber = described_class.new([secret])
    echoes = { "JSON with \\/" => secret.gsub("/", "\\/"), "JSON" => JSON.generate(secret)[1...-1],
               "URL" => URI.encode_www_form_component(secret),
               "URL, lower case" => URI.encode_www_form_component(secret).gsub(/%\h\h/, &:downcase) }

    echoes.each do |label, echo|
      expect(scrubber.scrub("said #{echo} back")).to eq("said [REDACTED] back"), label
    end
  end

  it "removes any 12-character window of a long value, and merges windows that overlap" do
    windows = (0..(key.length - 12)).map { key[_1, 12] }
    windows.each do |window|
      expect(scrubber.scrub("<<#{window}>>")).to eq("<<[REDACTED]>>"), window
    end
    expect(scrubber.scrub("x#{key[3, 20]}y")).to eq("x[REDACTED]y")
    expect(scrubber.scrub("#{key[0, 14]}--#{key[-13..]}")).to eq("[REDACTED]--[REDACTED]")
  end

  it "keeps text that holds no value or window, and an 11-character run of a value" do
    text = "Incorrect API key provided: #{key[0, 8]}****#{key[-4..]} (#{key[2, 11]})"

    expect(scrubber.scrub(text)).to eq(text)
    expect(scrubber.holds?(text)).to be(false)
    expect(scrubber.scrub("")).to eq("")
  end

  it "keeps the text's encoding and validity around what it removes" do
    text = "clé #{key} ünïcode"
    scrubbed = scrubber.scrub(text)

    expect(scrubbed).to eq("clé [REDACTED] ünïcode")
    expect([scrubbed.encoding, scrubbed.valid_encoding?]).to eq([Encoding::UTF_8, true])
  end

  it "adds values without forgetting the ones it had" do
    later = scrubber.with(["another-secret-value-1234"])

    expect(later.scrub("#{key} another-secret-value-1234")).to eq("[REDACTED] [REDACTED]")
    expect(scrubber.scrub("another-secret-value-1234")).to eq("another-secret-value-1234")
  end
end
