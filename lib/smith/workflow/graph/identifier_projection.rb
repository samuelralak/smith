# frozen_string_literal: true

module Smith
  class Workflow
    class Graph
      class IdentifierProjection
        def call(value)
          Identifier.normalize(value, label: "graph identifier", allow_nil: true)
        end
      end
    end
  end
end
