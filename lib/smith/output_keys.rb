# frozen_string_literal: true

module Smith
  # Reading a structured agent output by key, whichever way the key is
  # spelled. A provider's reply reaches a step as parsed JSON, with String
  # keys; a host's after_completion may give Symbols. As MessageRoles.role
  # and optimize's rejected_round_note do, a key is looked up as given,
  # then in its other spelling, and the output is never rewritten. `O(1)`
  # a key.
  module OutputKeys
    module_function

    def key?(data, key) = data.key?(key) || data.key?(other_spelling(key))

    def read(data, key) = data.key?(key) ? data[key] : data[other_spelling(key)]

    # Whether the key holds a value: strict structured output gives every
    # key, the unused ones null.
    def value?(data, key) = key?(data, key) && !read(data, key).nil?

    def other_spelling(key)
      case key
      when Symbol then key.name
      when String then key.to_sym
      else key
      end
    end
  end
end
