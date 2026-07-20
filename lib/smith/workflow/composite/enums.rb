# frozen_string_literal: true

module Smith
  class Workflow
    module Composite
      module Enums
        VALUES = {
          kind: { "parallel" => :parallel, "fanout" => :fanout }.freeze,
          status: { "succeeded" => :succeeded, "failed" => :failed }.freeze,
          resume_policy: { "incomplete_only" => :incomplete_only }.freeze,
          failure_policy: { "host_committed_primary" => :host_committed_primary }.freeze,
          reduction_policy: { "ordered_all_success" => :ordered_all_success }.freeze,
          retry_policy: { "none" => :none }.freeze
        }.freeze
        private_constant :VALUES

        def self.normalize(name, value)
          return value unless value.is_a?(String)

          VALUES.fetch(name).fetch(value, value)
        end
      end

      private_constant :Enums
    end
  end
end
