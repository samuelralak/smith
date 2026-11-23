# frozen_string_literal: true

module Smith
  module Evals
    module SuiteManifest
      # Internal. A suite's fixed targets (judged in slice 1b): each id a
      # unique code, its scorer one of the suite's, its reducer one of that
      # scorer's (the headline by default), its target from 0 to 1.
      class GateCheck
        include Facts

        ID = /\A[a-z][a-z0-9_]{0,63}\z/

        def initialize(gates, scorers, problems)
          @gates = gates
          @scorers = scorers
          @problems = problems
          @problems << "/gates: holds at most #{MAX_GATES} gates" if gates.size > MAX_GATES
          gates.each_with_index { |gate, index| check(gate, "/gates/#{index}", gates.first(index)) }
        end

        def manifest
          @gates.map do |gate|
            { "id" => gate[:id].to_s, "kind" => "at_least", "scorer" => gate[:scorer].to_s,
              "reducer" => reducer(gate), "target" => Float(gate[:target]) }
          end
        end

        private

        def check(gate, path, before)
          id = gate[:id].to_s
          @problems << "#{path}/id: is a code (^[a-z][a-z0-9_]{0,63}$)" unless matches?(id, ID)
          @problems << "#{path}/id: #{id} is used by another gate" if before.any? { _1[:id].to_s == id }
          target = gate[:target]
          @problems << "#{path}/target: is a number from 0 to 1" unless real?(target) && target.between?(0, 1)
          check_reducer(gate, path)
        end

        def check_reducer(gate, path)
          entry = @scorers.named(gate[:scorer])
          if entry.nil?
            @problems << "#{path}/scorer: names no scorer of this suite" unless @scorers.declared?(gate[:scorer])
            return
          end
          return if [entry.reduce, *entry.also].include?(reducer(gate))

          @problems << "#{path}/reducer: is one of the scorer's reducers"
        end

        def reducer(gate)
          return @scorers.named(gate[:scorer]).reduce if gate[:reducer].nil?

          SuiteManifest.reducer_name(gate[:reducer])
        end
      end
      private_constant :GateCheck
    end
  end
end
