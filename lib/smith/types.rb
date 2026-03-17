# frozen_string_literal: true

require "dry-types"

module Smith
  module Types
    include Dry.Types()

    # Dry.Types() resolves constants via const_missing, which means
    # const_defined?(:String, false) returns false. Contract specs use
    # strict const_defined?(name, false) lookups, so we materialize
    # the constants we need as direct module constants.
    const_set(:String, const_get(:String))
    const_set(:Integer, const_get(:Integer))
  end
end
