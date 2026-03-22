# frozen_string_literal: true

module Smith
  class Workflow
    class Pipeline
      attr_reader :name, :from, :to, :stages, :failure_transition

      def initialize(name, from:, to:, &)
        raise WorkflowError, "pipeline name is required" if name.nil?
        raise WorkflowError, "pipeline :#{name} requires from:" if from.nil?
        raise WorkflowError, "pipeline :#{name} requires to:" if to.nil?

        @name = name
        @from = from
        @to = to
        @stages = []
        @failure_transition = nil
        instance_eval(&)
      end

      def stage(stage_name, execute:)
        raise WorkflowError, "pipeline :#{name} stage name is required" if stage_name.nil?
        raise WorkflowError, "pipeline :#{name} stage :#{stage_name} requires execute:" if execute.nil?

        @stages << { name: stage_name, agent: execute }
      end

      def on_failure(transition_name)
        @failure_transition = transition_name
      end

      def compile!(workflow_class)
        validate!
        validate_no_collisions!(workflow_class)
        generate_transitions(workflow_class)
      end

      private

      def validate!
        raise WorkflowError, "pipeline :#{name} must declare at least one stage" if stages.empty?

        seen = {}
        stages.each do |stg|
          raise WorkflowError, "pipeline :#{name} has duplicate stage :#{stg[:name]}" if seen[stg[:name]]

          seen[stg[:name]] = true
        end
      end

      def validate_no_collisions!(workflow_class)
        stages.each do |stg|
          t_name = stage_transition_name(stg)
          next unless workflow_class.find_transition(t_name)

          raise WorkflowError, "pipeline :#{name} transition :#{t_name} collides with existing transition"
        end
      end

      def generate_transitions(workflow_class)
        stages.each_with_index do |stg, idx|
          declare_intermediate_state(workflow_class, idx)
          register_stage_transition(workflow_class, stg, idx)
        end
      end

      def declare_intermediate_state(workflow_class, idx)
        return if idx.zero?

        workflow_class.state(stage_after_state(stages[idx - 1]))
      end

      def register_stage_transition(workflow_class, stg, idx)
        attrs = stage_attributes(stg, idx)

        workflow_class.transition(attrs[:name], from: attrs[:from], to: attrs[:to]) do
          execute attrs[:agent]
          on_success attrs[:next] if attrs[:next]
          on_failure attrs[:fail] if attrs[:fail]
        end
      end

      def stage_attributes(stg, idx)
        { name: stage_transition_name(stg), from: stage_from(idx), to: stage_to(stg, idx),
          next: stage_next(idx), fail: failure_transition, agent: stg[:agent] }
      end

      def stage_from(idx)
        idx.zero? ? from : stage_after_state(stages[idx - 1])
      end

      def stage_to(stg, idx)
        idx == stages.length - 1 ? to : stage_after_state(stg)
      end

      def stage_next(idx)
        idx < stages.length - 1 ? stage_transition_name(stages[idx + 1]) : nil
      end

      def stage_transition_name(stg)
        :"#{name}__#{stg[:name]}"
      end

      def stage_after_state(stg)
        :"#{name}__after_#{stg[:name]}"
      end
    end

    module DSL
      module ClassMethods
        def pipeline(name, from:, to:, &)
          Pipeline.new(name, from: from, to: to, &).compile!(self)
        end
      end
    end
  end
end
