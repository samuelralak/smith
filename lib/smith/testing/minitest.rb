# frozen_string_literal: true

require "smith/testing"

module Smith
  module Testing
    # Minitest assertions for workflow runs (`include
    # Smith::Testing::Assertions`); stubs are dropped after each test.
    #
    #   assert_waiting_for run, :approval
    #   assert_waiting_for run, kind: :batch
    #   assert_transitioned_through run, :triage, :draft
    #   assert_usage_recorded run, agent_name: Triager, input_tokens: 40
    #   assert_usage_recorded run, count: 2, mode: :batch
    module Assertions
      def assert_waiting_for(workflow, event = nil, kind: nil)
        failure = Checks.waiting_for(workflow, event, kind:)
        assert(failure.nil?, failure)
      end

      def assert_transitioned_through(workflow, *names)
        failure = Checks.transitioned_through(workflow, names)
        assert(failure.nil?, failure)
      end

      def assert_usage_recorded(workflow, count: nil, **attributes)
        failure = Checks.usage_recorded(workflow, count:, **attributes)
        assert(failure.nil?, failure)
      end

      def after_teardown
        super
        Testing.reset!
      end
    end
  end
end
