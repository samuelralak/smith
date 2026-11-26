# frozen_string_literal: true

module Smith
  module Tuning
    # Experimental. A tuning run's minibatches (slice 5a design, section 1,
    # row 4): b training ids at a time from a shuffle of the training set,
    # epoch by epoch, without replacement. The paper does not say how;
    # this draws each id uniformly from those the epoch has not used, with
    # the run's one generator, which is a shuffle drawn as it is needed. A
    # tail shorter than b starts the next epoch, so no minibatch holds an
    # id twice. The cursor ({epoch, position}) and the ids the lines drew
    # restore it: the epoch's used ids are the last `position` drawn. O(b n)
    # a minibatch for n training ids, O(n) to restore.
    class Minibatches
      attr_reader :epoch

      # Rebuilt from an iteration line's cursor and every id the run's
      # minibatches drew, in order.
      def self.restore(train_ids, size:, cursor:, drawn:)
        epoch, position = cursor.values_at("epoch", "position") if cursor.is_a?(Hash)
        unless epoch.is_a?(Integer) && epoch >= 0 && position.is_a?(Integer) && position.between?(0, drawn.size)
          raise ArgumentError, "the cursor does not fit the ids drawn"
        end

        new(train_ids, size:, epoch:, used: drawn.last(position))
      end

      def initialize(train_ids, size:, epoch: 0, used: [])
        if size > train_ids.size
          raise ArgumentError, "a minibatch of #{size} cannot be drawn from #{train_ids.size} training samples"
        end
        raise ArgumentError, "the cursor does not fit the ids drawn" unless (used - train_ids).empty?

        @train_ids = train_ids
        @size = size
        @epoch = epoch
        @used = used.size
        @left = train_ids - used
      end

      # The next minibatch, drawing from `rng` (the run's SplitMix64).
      def next(rng)
        start_epoch if @left.size < @size
        @used += @size
        Array.new(@size) { @left.delete_at(rng.below(@left.size)) }.freeze
      end

      # What an iteration line saves.
      def cursor = { "epoch" => @epoch, "position" => @used }

      private

      def start_epoch
        @epoch += 1
        @used = 0
        @left = @train_ids.dup
      end
    end
  end
end
