# frozen_string_literal: true

module Smith
  module Events
    class StepCompleted < Smith::Event
      attribute :transition, Types::Strict::Symbol
      attribute :from, Types::Strict::Symbol.optional
      attribute :to, Types::Strict::Symbol
      # The emitting workflow's class name; distinguishes nested-child steps
      # from parent steps under the shared root execution identity.
      attribute :workflow, Types::Strict::String.optional.default(nil)
    end
  end
end
