# frozen_string_literal: true

module Smith
  class Workflow
    class Transition
      attr_reader :name, :from, :to, :agent_name, :agent_opts, :success_transition, :failure_transition,
                  :router_config, :workflow_class, :optimization_config, :orchestrator_config,
                  :deterministic_block, :deterministic_kind

      def initialize(name, from:, to:, &)
        @name = name
        @from = from
        @to = to
        instance_eval(&) if block_given?
      end

      def execute(agent_name, **opts)
        raise WorkflowError, "transition cannot declare both execute and compute/run" if @deterministic_block

        @agent_name = agent_name
        @agent_opts = opts
      end

      def on_success(transition_name)
        @success_transition = transition_name
      end

      def on_failure(transition_name)
        @failure_transition = transition_name
      end

      def route(agent_name, routes:, confidence_threshold:, fallback:)
        raise WorkflowError, "transition cannot declare both route and compute/run" if @deterministic_block

        @agent_name = agent_name
        @router_config = { routes: routes, confidence_threshold: confidence_threshold, fallback: fallback }
      end

      def workflow(klass)
        raise WorkflowError, "workflow binding must be a Class" unless klass.is_a?(Class)
        raise WorkflowError, "workflow binding must be a Smith::Workflow subclass" unless klass < Workflow
        raise WorkflowError, "transition cannot declare both workflow and execute" if @agent_name && !@router_config
        raise WorkflowError, "transition cannot declare both workflow and route" if @router_config
        raise WorkflowError, "transition cannot declare both workflow and compute/run" if @deterministic_block

        @workflow_class = klass
      end

      def optimize(generator:, evaluator:, max_rounds:, evaluator_schema:, improvement_threshold: nil)
        validate_optimize_conflicts!
        validate_optimize_controls!(generator, evaluator, max_rounds, evaluator_schema)

        @optimization_config = {
          generator: generator, evaluator: evaluator, max_rounds: max_rounds,
          evaluator_schema: evaluator_schema, improvement_threshold: improvement_threshold
        }
      end

      def orchestrate(**opts)
        validate_orchestrate_conflicts!
        validate_orchestrate_controls!(opts)
        @orchestrator_config = opts
      end

      %i[compute run].each do |method_name|
        define_method(method_name) do |&block|
          validate_deterministic_conflicts!
          raise WorkflowError, "#{method_name} requires a block" unless block

          @deterministic_block = block
          @deterministic_kind = method_name
        end
      end

      def deterministic?
        !@deterministic_block.nil?
      end

      def orchestrated?
        !@orchestrator_config.nil?
      end

      def optimized?
        !@optimization_config.nil?
      end

      def nested?
        !@workflow_class.nil?
      end

      def routed?
        !@router_config.nil?
      end

      def parallel?
        agent_opts&.dig(:parallel) == true
      end

      private

      def validate_deterministic_conflicts!
        raise WorkflowError, "transition cannot declare both compute/run and execute" if @agent_name && !@router_config
        raise WorkflowError, "transition cannot declare both compute/run and route" if @router_config
        raise WorkflowError, "transition cannot declare both compute/run and workflow" if @workflow_class
        raise WorkflowError, "transition cannot declare both compute/run and optimize" if @optimization_config
        raise WorkflowError, "transition cannot declare both compute/run and orchestrate" if @orchestrator_config
        raise WorkflowError, "transition cannot declare both compute and run" if @deterministic_block
      end

      def validate_optimize_conflicts!
        raise WorkflowError, "transition cannot declare both optimize and execute" if @agent_name && !@router_config
        raise WorkflowError, "transition cannot declare both optimize and route" if @router_config
        raise WorkflowError, "transition cannot declare both optimize and workflow" if @workflow_class
        raise WorkflowError, "transition cannot declare both optimize and compute/run" if @deterministic_block
      end

      def validate_orchestrate_conflicts!
        raise WorkflowError, "transition cannot declare both orchestrate and execute" if @agent_name && !@router_config
        raise WorkflowError, "transition cannot declare both orchestrate and route" if @router_config
        raise WorkflowError, "transition cannot declare both orchestrate and workflow" if @workflow_class
        raise WorkflowError, "transition cannot declare both orchestrate and optimize" if @optimization_config
        raise WorkflowError, "transition cannot declare both orchestrate and compute/run" if @deterministic_block
      end

      def validate_orchestrate_controls!(opts)
        validate_orchestrate_required_fields!(opts)
        validate_orchestrate_bounds!(opts)
      end

      def validate_orchestrate_required_fields!(opts)
        raise WorkflowError, "orchestrate requires an orchestrator" if opts[:orchestrator].nil?
        raise WorkflowError, "orchestrate requires a worker" if opts[:worker].nil?

        validate_schema_surface!(:task_schema, opts[:task_schema])
        validate_schema_surface!(:worker_output_schema, opts[:worker_output_schema])
        validate_schema_surface!(:final_output_schema, opts[:final_output_schema])
      end

      def validate_schema_surface!(name, schema)
        raise WorkflowError, "orchestrate requires a #{name}" if schema.nil?
        return if schema.respond_to?(:required_keys)

        raise WorkflowError, "orchestrate #{name} must respond to :required_keys"
      end

      def validate_orchestrate_bounds!(opts)
        unless opts[:max_workers].is_a?(Integer) && opts[:max_workers].positive?
          raise WorkflowError, "orchestrate max_workers must be a positive integer"
        end
        return if opts[:max_delegation_rounds].is_a?(Integer) && opts[:max_delegation_rounds].positive?

        raise WorkflowError, "orchestrate max_delegation_rounds must be a positive integer"
      end

      def validate_optimize_controls!(generator, evaluator, max_rounds, evaluator_schema)
        raise WorkflowError, "optimize requires a generator" if generator.nil?
        raise WorkflowError, "optimize requires an evaluator" if evaluator.nil?
        raise WorkflowError, "optimize requires an evaluator_schema" if evaluator_schema.nil?

        return if max_rounds.is_a?(Integer) && max_rounds.positive?

        raise WorkflowError, "optimize max_rounds must be a positive integer"
      end
    end
  end
end
