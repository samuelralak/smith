# frozen_string_literal: true

module Smith
  module Evals
    Actor = Data.define(:kind, :id)

    # Experimental. Who did something to an eval run or a dataset: a person,
    # a service (an API key, a CI job) or a policy (an automatic rule), by
    # the host's own id. Records store it as {"kind", "id"}.
    #
    #   Smith::Evals::Actor.person("usr_51a8").to_h # => {"kind" => "person", "id" => "usr_51a8"}
    class Actor
      KINDS = %w[person service policy].freeze
      MAX_ID_CHARACTERS = 256

      def initialize(kind:, id:)
        kind = kind.name if kind.is_a?(Symbol)
        raise ArgumentError, "an actor's kind is person, service or policy" unless KINDS.include?(kind)
        raise ArgumentError, "an actor's id is a String of 1 to 256 characters" unless id?(id)

        super(kind: kind.dup.freeze, id: id.dup.force_encoding(Encoding::UTF_8).freeze)
      end

      def self.person(id) = new(kind: "person", id:)
      def self.service(id) = new(kind: "service", id:)
      def self.policy(id) = new(kind: "policy", id:)

      # An actor from its record form, or nil from nil.
      def self.from_h(value)
        return if value.nil?
        raise ArgumentError, "an actor is a Hash with kind and id" unless value.is_a?(Hash)

        new(kind: value["kind"] || value[:kind], id: value["id"] || value[:id])
      end

      def to_h = { "kind" => kind, "id" => id }

      private

      # UTF-8, or ASCII in any encoding, as every other check takes text.
      def id?(id)
        id.is_a?(String) && ((id.encoding == Encoding::UTF_8 && id.valid_encoding?) || id.ascii_only?) &&
          id.length.between?(1, MAX_ID_CHARACTERS)
      end
    end
  end
end
