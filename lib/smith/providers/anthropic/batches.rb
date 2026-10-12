# frozen_string_literal: true

require "json"
require "ruby_llm"

module Smith
  module Providers
    module Anthropic
      # Anthropic's Message Batches API, over RubyLLM's configured Anthropic
      # connection (its key and base URL), for the host to submit the
      # requests Smith's batch queue took, read a batch's status, collect its
      # results and cancel it. Smith calls none of these: the host schedules
      # them, then resumes each run with the results of its wait.
      #
      #   batches = Smith::Providers::Anthropic::Batches.new
      #   batch_id = batches.submit(queued)   # [{ custom_id:, request: }, ...], as enqueued
      #   batches.status(batch_id)            # => { status: "in_progress" | "canceling" | "ended", counts: {...} }
      #   batches.results(batch_id) { |custom_id, result| ... }
      #
      # A batch takes at most 100,000 requests and 256 MB, and every request
      # in it the same per-call headers (a beta feature's, say), which never
      # override the connection's own (its key and API version). The
      # connection makes no retries of its own, so a submit is never sent
      # twice; the host's schedule tries again.
      class Batches
        PATH = "v1/messages/batches"
        MAX_REQUESTS = 100_000
        MAX_BYTES = 256 * 1024 * 1024
        BATCH_ID = /\A[A-Za-z0-9_-]{1,128}\z/

        def initialize(config: RubyLLM.config)
          config = config.dup
          config.max_retries = 0
          @connection = RubyLLM::Providers::Anthropic.new(config).connection
        end

        # Submits the requests; returns the batch id. A refusal for want of
        # credit raises RubyLLM::PaymentRequiredError (BillingRefusals).
        def submit(requests)
          entries = Array(requests).map { |entry| entry.transform_keys(&:to_sym) }
          body = { requests: entries.map { |entry| { custom_id: entry.fetch(:custom_id), params: params(entry) } } }
          check_batch!(entries, body)
          create(body, shared_headers(entries))
        end

        # The batch's processing status ("in_progress", "canceling" or
        # "ended") and its request counts.
        def status(batch_id)
          body = @connection.get("#{PATH}/#{id!(batch_id)}").body
          { status: body.fetch("processing_status"), counts: body["request_counts"], ended_at: body["ended_at"],
            expires_at: body["expires_at"] }
        end

        # Yields each result of an ended batch as [custom_id, result].
        def results(batch_id)
          return enum_for(:results, batch_id) unless block_given?

          body = @connection.get("#{PATH}/#{id!(batch_id)}/results").body
          entries(body).each { |entry| yield entry.fetch("custom_id"), entry.fetch("result") }
          nil
        end

        # Asks the provider to stop the batch; returns its status.
        def cancel(batch_id)
          @connection.post("#{PATH}/#{id!(batch_id)}/cancel", {}).body.fetch("processing_status")
        end

        private

        def create(body, headers)
          @connection.post(PATH, body) { |request| add_headers(request.headers, headers) }.body.fetch("id")
        rescue RubyLLM::Error => e
          raise BillingRefusals.classified(e)
        end

        def params(entry)
          request = entry.fetch(:request).transform_keys(&:to_s)
          raise ArgumentError, "a request for #{request["provider"]} cannot go in an Anthropic batch" unless
            request["provider"] == "anthropic"

          request.fetch("params")
        end

        def check_batch!(entries, body)
          unless entries.length.between?(1, MAX_REQUESTS)
            raise ArgumentError, "a batch takes 1 to #{MAX_REQUESTS} requests, not #{entries.length}"
          end
          return if JSON.generate(body).bytesize <= MAX_BYTES

          raise ArgumentError, "a batch takes at most #{MAX_BYTES} bytes; split the requests"
        end

        def shared_headers(entries)
          headers = entries.map { |entry| entry.fetch(:request).transform_keys(&:to_s).fetch("headers", {}).to_h }.uniq
          raise ArgumentError, "the requests of one batch must share their headers" if headers.length > 1

          headers.first
        end

        # The requests' own headers, under the connection's (its key and API
        # version win).
        def add_headers(request_headers, headers)
          headers.each { |name, value| request_headers[name] = value unless request_headers.key?(name) }
        end

        def id!(batch_id)
          return batch_id if batch_id.is_a?(String) && BATCH_ID.match?(batch_id)

          raise ArgumentError, "not a batch id: #{batch_id.inspect}"
        end

        # The results file: one JSON object per line.
        def entries(body)
          return body if body.is_a?(Array)
          return [body] if body.is_a?(Hash)

          body.to_s.each_line.filter_map { |line| JSON.parse(line) unless line.strip.empty? }
        end
      end
    end
  end
end
