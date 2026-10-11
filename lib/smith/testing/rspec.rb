# frozen_string_literal: true

require "smith/testing"

module Smith
  module Testing
    # RSpec matchers for workflow runs, included in every example group;
    # stubs are dropped after each example.
    #
    #   expect(run).to be_waiting_for(:approval)
    #   expect(run).to be_waiting_for(kind: :batch)
    #   expect(run).to have_transitioned_through(:triage, :draft)
    #   expect(run).to have_recorded_usage(agent_name: Triager, input_tokens: 40)
    module Matchers
      # One of the Checks as a matcher.
      class Matcher
        attr_reader :description, :failure_message

        def initialize(description, &check)
          @description = description
          @check = check
        end

        def matches?(workflow)
          @failure_message = @check.call(workflow)
          @failure_message.nil?
        end

        def failure_message_when_negated = "expected the run not to #{description}"
      end

      def be_waiting_for(event = nil, kind: nil)
        Matcher.new("wait for #{event || kind || "anything"}") { Checks.waiting_for(_1, event, kind:) }
      end

      # rubocop:disable Naming/PredicatePrefix -- RSpec's have_ matcher names
      def have_transitioned_through(*names)
        Matcher.new("go through #{names.join(", ")}") { Checks.transitioned_through(_1, names) }
      end

      def have_recorded_usage(count: nil, **attributes)
        Matcher.new("record usage #{attributes.inspect}") { Checks.usage_recorded(_1, count:, **attributes) }
      end
      # rubocop:enable Naming/PredicatePrefix
    end
  end
end

RSpec.configure do |config|
  config.include Smith::Testing::Matchers
  config.after { Smith::Testing.reset! }
end
