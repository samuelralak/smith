# frozen_string_literal: true

module Smith
  module Events
    class StepCompleted < Smith::Event
      attribute :transition, Types::Strict::Symbol
      attribute :from, Types::Strict::Symbol.optional
      attribute :to, Types::Strict::Symbol
    end
  end
end
