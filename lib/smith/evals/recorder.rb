# frozen_string_literal: true

require_relative "configuration"
require_relative "spend"
require_relative "recorder/step"

module Smith
  module Evals
    # Experimental. One trial attempt's step records (slice-1a design, 5.4):
    # Recording hands it each provider attempt observed under its trial,
    # from any thread, and it keeps one bounded step record for each (the
    # trial schema's $defs/step), in the order they arrived (`seq`, from 1),
    # its own copy, whatever Smith's trace content says. It keeps no
    # messages with `recording: { content: false }`.
    #
    # Bounds (`recording`, as Configuration#recording takes them): a
    # message's text, reply or thinking at max_message_bytes and a tool
    # result or tool call's arguments at max_tool_bytes, cut and marked; a
    # step past max_step_bytes has messages elided from its middle; once
    # the trial's step records pass max_trial_bytes, later ones keep their
    # metadata only; past max_steps the first ceil(max/2) and the last
    # floor(max/2) are kept and the middle dropped (`recording`'s
    # dropped_steps and dropped_seq), a dropped step's bytes freed for the
    # newer ones. `usage` (by provider and model too) and `counts` cover
    # every step it was given, dropped ones too.
    #
    # `started_at` is the trial attempt's start on the monotonic clock, each
    # step's offset_ms counted from it. Thread-safe: each step is built and
    # kept under one Mutex. Memory is bounded by max_trial_bytes plus
    # max_steps metadata records; O(B) per step for the B bytes it keeps.
    class Recorder
      private_constant :Fields, :Messages, :Step

      attr_reader :trial_id, :started_at

      def initialize(trial_id, recording: Configuration::RECORDING_DEFAULTS,
                     started_at: Process.clock_gettime(Process::CLOCK_MONOTONIC))
        raise ArgumentError, "a recorder's trial id is a String" unless trial_id.is_a?(String) && !trial_id.empty?

        @trial_id = trial_id.dup.freeze
        @bounds = Configuration.recording(recording)
        @started_at = started_at
        @head = []
        @tail = []
        @dropped = nil
        @seq = @bytes = @cut_fields = @dropped_steps = 0
        @spend = Spend.new
        @tool_calls = 0
        @lock = Mutex.new
      end

      # Keeps the observation's step record. Called by Recording.
      def record(attempt)
        @lock.synchronize do
          @seq += 1
          step = Step.new(attempt, seq: @seq, origin: @started_at, bounds: @bounds, content: @bounds[:content])
          make_room
          step.without_content if step.record["messages"] && @bytes + step.bytes > @bounds[:max_trial_bytes]
          @bytes += step.bytes if step.record["messages"]
          count(step)
          keep(step)
        end
        nil
      end

      # The step records kept, in seq order.
      def steps = @lock.synchronize { (@head + @tail).map(&:record).freeze }

      # The trial line's recording object: with `result`, a SubjectResult,
      # child runs no recorder followed are a gap (child_runs_not_followed);
      # `gaps` adds the record builder's own (output_cut, state_cut).
      # Complete when nothing was dropped or elided and no gap but
      # content_off applies.
      def recording(result = nil, gaps: [])
        found = gaps_of(result, gaps)
        @lock.synchronize do
          complete = @dropped_steps.zero? && (@head + @tail).none?(&:elided?) && (found - ["content_off"]).empty?
          { "complete" => complete, "dropped_steps" => @dropped_steps, "dropped_seq" => @dropped&.dup&.freeze,
            "cut_fields" => @cut_fields, "gaps" => found }.freeze
        end
      end

      # What every step it was given used: tokens, the cost of those priced
      # (complete only when each was), the requests that went to a provider,
      # and the same by provider and model (Spend).
      def usage = @lock.synchronize { @spend.usage }

      def counts
        @lock.synchronize do
          { "agent_attempts" => @seq, "tool_calls" => @tool_calls,
            "steps_recorded" => @head.length + @tail.length }.freeze
        end
      end

      private

      def gaps_of(result, gaps)
        found = []
        found << "child_runs_not_followed" if result&.child_runs.to_i.positive?
        found << "content_off" unless @bounds[:content]
        (found + gaps.map(&:to_s)).uniq.freeze
      end

      def count(step)
        record = step.record
        @spend.add(provider: record["provider"], model: record["model"], provider_calls: step.provider_call? ? 1 : 0,
                   tokens: step.tokens, cost_nanos: step.cost_nanos.to_i, cost_complete: step.cost_known)
        @tool_calls += step.tool_calls
        @cut_fields += step.cut_fields
      end

      # The head keeps the first ceil(max/2); the tail is a ring of the last
      # floor(max/2). Before a step joins a full ring its oldest is dropped
      # (the dropped are one run of seqs, from the middle), and the bytes its
      # messages took are freed for the newer step, so the last steps keep
      # theirs while they fit.
      def make_room
        forget(@tail.shift) if ring? && !@tail.empty? && @tail.length >= @bounds[:max_steps] / 2
      end

      def keep(step)
        return @head << step unless ring?
        return forget(step) if (@bounds[:max_steps] / 2).zero?

        @tail << step
      end

      def ring? = @head.length >= (@bounds[:max_steps] + 1) / 2

      def forget(step)
        @bytes -= step.bytes if step.record["messages"]
        seq = step.record["seq"]
        @dropped_steps += 1
        @dropped = [@dropped&.first || seq, seq]
      end
    end
  end
end
