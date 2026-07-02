# frozen_string_literal: true

module Smith
  class Workflow
    class Graph
      class Targets
        attr_reader :transition

        def self.for(transition)
          new(transition).names
        end

        def self.router_for(transition)
          new(transition).router_names
        end

        def initialize(transition)
          @transition = transition
        end

        def names
          names = [transition.success_transition, transition.failure_transition]
          names.concat(router_names)
          names.concat(deterministic_route_names)
          names.compact.uniq
        end

        def router_names
          return [] unless transition.router_config

          [
            *transition.router_config.fetch(:routes).values,
            transition.router_config.fetch(:fallback)
          ]
        end

        def deterministic_route_names
          transition.deterministic_routes || []
        end
      end
    end
  end
end
