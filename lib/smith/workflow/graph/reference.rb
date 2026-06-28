# frozen_string_literal: true

module Smith
  class Workflow
    class Graph
      module Reference
        def self.format(value)
          return ":#{value}" if value.is_a?(Symbol)

          value.inspect
        end
      end
    end
  end
end
