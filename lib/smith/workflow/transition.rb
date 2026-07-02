# frozen_string_literal: true

module Smith
  class Workflow
    class Transition
      attr_reader :name, :from, :to, :agent_name, :agent_opts, :success_transition, :failure_transition,
                  :router_config, :workflow_class, :optimization_config, :orchestrator_config,
                  :fanout_config, :retry_config, :deterministic_block, :deterministic_kind,
                  :deterministic_routes

      def initialize(name, from:, to:, &)
        @name = name
        @from = from
        @to = to
        instance_eval(&) if block_given?
      end

      def execute(agent_name, **opts)
        validate_execute_conflicts!

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
        validate_route_conflicts!

        @agent_name = normalize_agent_name!(agent_name, "router")
        @router_config = {
          routes: normalize_router_routes!(routes),
          confidence_threshold: normalize_confidence_threshold!(confidence_threshold),
          fallback: normalize_transition_reference!(fallback, "router fallback")
        }
      end

      def workflow(klass)
        raise WorkflowError, "workflow binding must be a Class" unless klass.is_a?(Class)
        raise WorkflowError, "workflow binding must be a Smith::Workflow subclass" unless klass < Workflow

        validate_conflicts!(
          "workflow",
          [
            ["execute", @agent_name && !@router_config],
            ["route", @router_config],
            ["compute/run", @deterministic_block],
            ["fan_out", @fanout_config]
          ]
        )

        @workflow_class = klass
      end

      def optimize(generator:, evaluator:, max_rounds:, evaluator_schema:,
                   improvement_threshold: nil,
                   evaluator_context: nil,
                   before_eval: nil,
                   on_exhaustion: :raise,
                   on_converged: :raise,
                   on_threshold: :raise)
        validate_optimize_conflicts!
        validate_optimize_controls!(generator, evaluator, max_rounds, evaluator_schema)
        validate_optimize_exit_modes!(on_exhaustion: on_exhaustion, on_converged: on_converged,
                                      on_threshold: on_threshold)
        validate_optimize_evaluator_context!(evaluator_context)
        validate_optimize_before_eval!(before_eval)

        @optimization_config = {
          generator: generator, evaluator: evaluator, max_rounds: max_rounds,
          evaluator_schema: evaluator_schema, improvement_threshold: improvement_threshold,
          evaluator_context: evaluator_context,
          before_eval: before_eval,
          on_exhaustion: on_exhaustion,
          on_converged: on_converged,
          on_threshold: on_threshold
        }
      end

      def orchestrate(**opts)
        validate_orchestrate_conflicts!
        validate_orchestrate_controls!(opts)
        @orchestrator_config = opts
      end

      def fan_out(branches:)
        validate_fanout_conflicts!

        @fanout_config = { branches: normalize_fanout_branches!(branches) }
      end
      alias fanout fan_out

      def retry_on(*error_classes, attempts:, backoff: 0, max_delay: nil, jitter: 0)
        validate_retry_controls!(error_classes, attempts:, backoff:, max_delay:, jitter:)

        @retry_config = {
          error_classes: error_classes.freeze,
          attempts: attempts,
          backoff: Float(backoff),
          max_delay: max_delay.nil? ? nil : Float(max_delay),
          jitter: Float(jitter)
        }.freeze
      end

      %i[compute run].each do |method_name|
        define_method(method_name) do |routes: nil, &block|
          validate_deterministic_conflicts!
          raise WorkflowError, "#{method_name} requires a block" unless block

          @deterministic_block = block
          @deterministic_kind = method_name
          @deterministic_routes = normalize_deterministic_routes!(routes)
        end
      end

      def deterministic?
        !@deterministic_block.nil?
      end

      def orchestrated?
        !@orchestrator_config.nil?
      end

      def fanout?
        !@fanout_config.nil?
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

      def validate_execute_conflicts!
        validate_conflicts!(
          "execute",
          [
            ["compute/run", @deterministic_block],
            ["fan_out", @fanout_config]
          ]
        )
      end

      def validate_route_conflicts!
        validate_conflicts!(
          "route",
          [
            ["compute/run", @deterministic_block],
            ["fan_out", @fanout_config]
          ]
        )
      end

      def validate_deterministic_conflicts!
        validate_conflicts!(
          "compute/run",
          [
            ["execute", @agent_name && !@router_config],
            ["route", @router_config],
            ["workflow", @workflow_class],
            ["optimize", @optimization_config],
            ["orchestrate", @orchestrator_config],
            ["fan_out", @fanout_config]
          ]
        )
        raise WorkflowError, "transition cannot declare both compute and run" if @deterministic_block
      end

      def validate_optimize_conflicts!
        validate_conflicts!(
          "optimize",
          [
            ["execute", @agent_name && !@router_config],
            ["route", @router_config],
            ["workflow", @workflow_class],
            ["compute/run", @deterministic_block],
            ["fan_out", @fanout_config]
          ]
        )
      end

      def validate_orchestrate_conflicts!
        validate_conflicts!(
          "orchestrate",
          [
            ["execute", @agent_name && !@router_config],
            ["route", @router_config],
            ["workflow", @workflow_class],
            ["optimize", @optimization_config],
            ["compute/run", @deterministic_block],
            ["fan_out", @fanout_config]
          ]
        )
      end

      def validate_fanout_conflicts!
        validate_conflicts!(
          "fan_out",
          [
            ["execute", @agent_name && !@router_config],
            ["route", @router_config],
            ["workflow", @workflow_class],
            ["optimize", @optimization_config],
            ["orchestrate", @orchestrator_config],
            ["compute/run", @deterministic_block]
          ]
        )
      end

      def validate_conflicts!(primitive, conflicts)
        conflicts.each do |other, present|
          raise WorkflowError, "transition cannot declare both #{primitive} and #{other}" if present
        end
      end

      def normalize_fanout_branches!(branches)
        raise WorkflowError, "fan_out branches must be a Hash" unless branches.is_a?(Hash)
        raise WorkflowError, "fan_out requires at least one branch" if branches.empty?

        normalized = branches.each_with_object({}) do |(branch_key, agent_name), map|
          key = normalize_fanout_branch_key!(branch_key)
          agent = normalize_fanout_agent_name!(agent_name, key)
          raise WorkflowError, "fan_out branch #{key.inspect} is duplicated" if map.key?(key)

          map[key] = agent
        end

        validate_distinct_fanout_agents!(normalized)
        normalized.freeze
      end

      def normalize_agent_name!(agent_name, label)
        value = agent_name.to_s.strip
        raise WorkflowError, "#{label} agent must not be blank" if value.empty?

        value.to_sym
      end

      def normalize_router_routes!(routes)
        raise WorkflowError, "router routes must be a Hash" unless routes.is_a?(Hash)
        raise WorkflowError, "router routes must not be empty" if routes.empty?

        routes.each_with_object({}) do |(route_key, transition_name), map|
          key = normalize_router_route_key!(route_key)
          raise WorkflowError, "router route :#{key} is duplicated" if map.key?(key)

          map[key] = normalize_transition_reference!(transition_name, "router route :#{key}")
        end.freeze
      end

      def normalize_router_route_key!(route_key)
        value = route_key.to_s.strip
        raise WorkflowError, "router route keys must not be blank" if value.empty?

        value.to_sym
      end

      def normalize_confidence_threshold!(threshold)
        numeric = Float(threshold)
        return numeric if numeric >= 0.0 && numeric <= 1.0

        raise WorkflowError, "router confidence_threshold must be a number in 0.0..1.0"
      rescue TypeError, ArgumentError
        raise WorkflowError, "router confidence_threshold must be a number in 0.0..1.0"
      end

      def normalize_transition_reference!(transition_name, label)
        case transition_name
        when Symbol
          raise WorkflowError, "#{label} transition must not be blank" if transition_name.to_s.empty?

          transition_name
        when String
          value = transition_name.strip
          raise WorkflowError, "#{label} transition must not be blank" if value.empty?

          value.freeze
        else
          raise WorkflowError, "#{label} transition must be String or Symbol"
        end
      end

      def normalize_fanout_branch_key!(branch_key)
        key = branch_key.to_s.strip
        raise WorkflowError, "fan_out branch keys must not be blank" if key.empty?

        key.to_sym
      end

      def normalize_fanout_agent_name!(agent_name, branch_key)
        value = agent_name.to_s.strip
        raise WorkflowError, "fan_out branch #{branch_key.inspect} must declare an agent" if value.empty?

        value.to_sym
      end

      def validate_distinct_fanout_agents!(branches)
        duplicates = branches.values.tally.select { |_agent, count| count > 1 }.keys
        return if duplicates.empty?

        raise WorkflowError, "fan_out branch agents must be distinct: #{duplicates.map(&:inspect).join(", ")}"
      end

      def validate_retry_controls!(error_classes, attempts:, backoff:, max_delay:, jitter:)
        unless attempts.is_a?(Integer) && attempts.positive?
          raise WorkflowError, "retry_on attempts must be a positive integer"
        end

        error_classes.each do |error_class|
          next if error_class.is_a?(Class) && error_class <= StandardError

          raise WorkflowError, "retry_on error classes must inherit from StandardError"
        end

        validate_non_negative_numeric!(:backoff, backoff)
        validate_non_negative_numeric!(:jitter, jitter)
        validate_non_negative_numeric!(:max_delay, max_delay) unless max_delay.nil?
      end

      def normalize_deterministic_routes!(routes)
        return nil if routes.nil?
        raise WorkflowError, "deterministic routes must be an Array" unless routes.is_a?(Array)
        raise WorkflowError, "deterministic routes must not be empty" if routes.empty?

        routes.each_with_object([]) do |route, list|
          name = normalize_deterministic_route!(route)
          raise WorkflowError, "deterministic route #{name.inspect} is duplicated" if list.include?(name)

          list << name
        end.freeze
      end

      def normalize_deterministic_route!(route)
        case route
        when Symbol
          raise WorkflowError, "deterministic route names must not be blank" if route.to_s.empty?

          route
        when String
          value = route.strip
          raise WorkflowError, "deterministic route names must not be blank" if value.empty?

          value.freeze
        else
          raise WorkflowError, "deterministic route names must be String or Symbol"
        end
      end

      def validate_non_negative_numeric!(name, value)
        numeric = Float(value)
        return if numeric >= 0.0

        raise WorkflowError, "retry_on #{name} must be non-negative"
      rescue TypeError, ArgumentError
        raise WorkflowError, "retry_on #{name} must be numeric"
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

      VALID_EXIT_MODES = %i[raise return_last].freeze
      private_constant :VALID_EXIT_MODES

      def validate_optimize_exit_modes!(on_exhaustion:, on_converged:, on_threshold:)
        { on_exhaustion: on_exhaustion, on_converged: on_converged, on_threshold: on_threshold }.each do |name, value|
          next if VALID_EXIT_MODES.include?(value)
          next if value.respond_to?(:call)

          raise WorkflowError,
                "optimize #{name} must be :raise, :return_last, or a callable; got #{value.inspect}"
        end
      end

      def validate_optimize_evaluator_context!(evaluator_context)
        return if evaluator_context.nil? || evaluator_context == :inject_state

        raise WorkflowError,
              "optimize evaluator_context must be nil or :inject_state; got #{evaluator_context.inspect}"
      end

      def validate_optimize_before_eval!(before_eval)
        return if before_eval.nil?
        return if before_eval.respond_to?(:call)

        raise WorkflowError, "optimize before_eval must respond to :call; got #{before_eval.inspect}"
      end
    end
  end
end
