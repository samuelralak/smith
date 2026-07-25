# frozen_string_literal: true

require_relative "../error"

module Smith
  module Models
    class AmbiguousProfileError < Smith::Error; end
  end
end
