# frozen_string_literal: true

require "dry-initializer"

module Smith
  class Workflow
    module SplitStepPersistence
      class TransitionContract
        extend Dry::Initializer

        MAX_DEPTH = 128
        MAX_NODES = 10_000
        MAX_BYTES = 4 * 1024 * 1024

        param :transition

        def self.capture(transition) = new(transition).capture
        def self.signature(transition) = new(transition).signature

        def capture
          captured = signature
          freeze_value(transition)
          freeze_value(captured)
          captured
        end

        def signature
          TransitionContractSignature.new(
            value: transition,
            max_depth: MAX_DEPTH,
            max_nodes: MAX_NODES,
            max_bytes: MAX_BYTES
          ).call
        end

        private

        def freeze_value(value)
          TransitionContractFreezer.new(
            value: value,
            max_depth: MAX_DEPTH,
            max_nodes: MAX_NODES
          ).call
        end
      end
    end
  end
end
