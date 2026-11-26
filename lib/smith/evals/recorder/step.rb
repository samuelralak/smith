# frozen_string_literal: true

require_relative "../../canonical_json"
require_relative "fields"
require_relative "messages"

module Smith
  module Evals
    class Recorder
      # One step record from one observation (slice-1a design, 5.4; the trial
      # schema's $defs/step): plain JSON with String keys, frozen, its fields
      # read by Fields and its messages bounded by Messages, within
      # max_step_bytes. Its offset is its start from the trial attempt's, on
      # the monotonic clock. Internal. O(B) in the bytes kept.
      class Step
        attr_reader :record, :bytes, :cut_fields

        # `origin`: the trial attempt's start on the monotonic clock. With
        # `content` false the record keeps no messages.
        def initialize(attempt, seq:, origin:, bounds:, content:)
          @attempt = attempt
          @cut_fields = 0
          @before, @after = Fields.of(attempt, seq, offset_ms(origin))
          kept, elided = content ? kept_messages(bounds) : [nil, 0]
          @record = build(kept, elided)
          @bytes = CanonicalJSON.generate(@record).bytesize
        end

        # The record without its messages, once the trial's bytes are spent:
        # nothing cut is left in it.
        def without_content
          @cut_fields = 0
          @record = build(nil, 0, content_dropped: true)
          @bytes = CanonicalJSON.generate(@record).bytesize
          self
        end

        def cost_nanos = @record["cost_nanos"]
        def cost_known = @record["cost_known"]
        def tokens = @record["tokens"]
        def tool_calls = @record["tool_calls"]

        # A request went to a provider: not skipped, not answered from a
        # memo, and its call started.
        def provider_call? = @attempt.outcome != :skipped && !@attempt.memo && !@attempt.duration_ms.nil?

        def elided? = @record["cut"]["elided_messages"].positive? || @record["cut"]["content_dropped"]

        private

        # Within max_step_bytes: the room the rest of the record leaves, less
        # the digits its elided count may take.
        def kept_messages(bounds)
          messages = Messages.new(bounds)
          copied = messages.copy(Array(@attempt.messages))
          @cut_fields = messages.cut_fields
          room = bounds.fetch(:max_step_bytes) - CanonicalJSON.generate(build([], 0)).bytesize -
                 copied.length.to_s.length
          Messages.fitted(copied, [room, 0].max)
        end

        def build(messages, elided, content_dropped: false)
          { **@before, "messages" => messages, **@after,
                       "cut" => { "fields" => @cut_fields, "elided_messages" => elided,
                                  "content_dropped" => content_dropped }.freeze }.freeze
        end

        def offset_ms(origin)
          started = @attempt.started
          return if started.nil? || origin.nil?

          [((started - origin) * 1000).round, 0].max
        end
      end
    end
  end
end
