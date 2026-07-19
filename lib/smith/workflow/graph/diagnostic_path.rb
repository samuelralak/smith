# frozen_string_literal: true

require "dry-initializer"

module Smith
  class Workflow
    class Graph
      class DiagnosticPath
        extend Dry::Initializer

        option :label
        option :tail, default: proc {}

        def each_label
          current = self
          while current
            yield current.label
            current = current.tail
          end
        end
      end
    end
  end
end
