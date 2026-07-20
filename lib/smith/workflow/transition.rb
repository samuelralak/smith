# frozen_string_literal: true

module Smith
  class Workflow
    class Transition
      attr_reader :name, :from, :to, :agent_name, :agent_opts, :success_transition, :failure_transition,
                  :router_config, :workflow_class, :optimization_config, :orchestrator_config,
                  :fanout_config, :retry_config, :deterministic_block, :deterministic_kind,
                  :deterministic_routes

      def initialize(name, from:, to:, &)
        @name = own_identifier(name)
        @from = own_identifier(from, allow_nil: true)
        @to = own_identifier(to)
        instance_eval(&) if block_given?
      end

      def execute(agent_name, **opts)
        validate_execution_primitive_conflict!("execute")

        normalized_agent = normalize_agent_reference!(agent_name, "agent")
        validate_parallel_options!(opts)

        @agent_name = normalized_agent
        @agent_opts = opts.freeze
        commit_execution_primitive!("execute")
      end

      def on_success(transition_name)
        if routed?
          raise WorkflowError, "routed transitions cannot declare on_success; router routes select the next transition"
        end

        @success_transition = own_identifier(transition_name)
      end

      def on_failure(transition_name)
        @failure_transition = own_identifier(transition_name)
      end

      def route(agent_name, routes:, confidence_threshold:, fallback:)
        validate_execution_primitive_conflict!("route")
        if @success_transition
          raise WorkflowError, "routed transitions cannot declare on_success; router routes select the next transition"
        end

        normalized_agent = normalize_agent_name!(agent_name, "router")
        normalized_config = {
          routes: normalize_router_routes!(routes),
          confidence_threshold: normalize_confidence_threshold!(confidence_threshold),
          fallback: normalize_transition_reference!(fallback, "router fallback")
        }.freeze

        @agent_name = normalized_agent
        @router_config = normalized_config
        commit_execution_primitive!("route")
      end

      def workflow(klass)
        raise WorkflowError, "workflow binding must be a Class" unless klass.is_a?(Class)
        raise WorkflowError, "workflow binding must be a Smith::Workflow subclass" unless klass < Workflow

        validate_execution_primitive_conflict!("workflow")

        @workflow_class = klass
        commit_execution_primitive!("workflow")
      end

      def optimize(generator:, evaluator:, max_rounds:, evaluator_schema:,
                   improvement_threshold: nil,
                   evaluator_context: nil,
                   before_eval: nil,
                   on_exhaustion: :raise,
                   on_converged: :raise,
                   on_threshold: :raise)
        validate_execution_primitive_conflict!("optimize")
        validate_optimize_controls!(generator, evaluator, max_rounds, evaluator_schema)
        validate_optimize_exit_modes!(on_exhaustion: on_exhaustion, on_converged: on_converged,
                                      on_threshold: on_threshold)
        validate_optimize_evaluator_context!(evaluator_context)
        validate_optimize_before_eval!(before_eval)

        config = {
          generator: normalize_agent_reference!(generator, "optimizer generator"),
          evaluator: normalize_agent_reference!(evaluator, "optimizer evaluator"),
          max_rounds: max_rounds,
          evaluator_schema: evaluator_schema, improvement_threshold: improvement_threshold,
          evaluator_context: evaluator_context,
          before_eval: before_eval,
          on_exhaustion: on_exhaustion,
          on_converged: on_converged,
          on_threshold: on_threshold
        }.freeze

        @optimization_config = config
        commit_execution_primitive!("optimize")
      end

      def orchestrate(**opts)
        validate_execution_primitive_conflict!("orchestrate")
        validate_orchestrate_controls!(opts)
        config = opts.merge(
          orchestrator: normalize_agent_reference!(opts.fetch(:orchestrator), "orchestrator"),
          worker: normalize_agent_reference!(opts.fetch(:worker), "orchestrator worker")
        ).freeze

        @orchestrator_config = config
        commit_execution_primitive!("orchestrate")
      end

      def fan_out(branches:)
        validate_execution_primitive_conflict!("fan_out")

        normalized = normalize_fanout_branches!(branches)
        @fanout_branch_lookup = normalized.to_h do |key, agent|
          [key.to_s.freeze, [key, agent].freeze]
        end.freeze
        config = { branches: normalized }.freeze

        @fanout_config = config
        commit_execution_primitive!("fan_out")
      end
      alias fanout fan_out

      def retry_on(*error_classes, attempts:, backoff: 0, max_delay: nil, jitter: 0)
        policy = normalize_retry_policy!(error_classes, attempts:, backoff:, max_delay:, jitter:)

        @retry_config = {
          error_classes: error_classes.freeze,
          attempts: policy.attempts,
          backoff: policy.base_delay,
          max_delay: policy.max_delay,
          jitter: policy.jitter
        }.freeze
      end

      %i[compute run].each do |method_name|
        define_method(method_name) do |routes: nil, &block|
          validate_execution_primitive_conflict!("compute/run", declaration: method_name.to_s)
          raise WorkflowError, "#{method_name} requires a block" unless block

          normalized_routes = normalize_deterministic_routes!(routes)

          @deterministic_block = block
          @deterministic_kind = method_name
          @deterministic_routes = normalized_routes
          commit_execution_primitive!("compute/run", declaration: method_name.to_s)
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

      def fetch_fanout_agent!(branch_key)
        fetch_fanout_branch!(branch_key).last
      end

      def fetch_fanout_branch!(branch_key)
        @fanout_branch_lookup.fetch(branch_key.to_s) do
          raise WorkflowError, "fan_out branch #{branch_key.inspect} is not declared"
        end
      end
      private :fetch_fanout_agent!, :fetch_fanout_branch!

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

      def own_identifier(identifier, allow_nil: false)
        Identifier.normalize(identifier, label: "workflow identifier", allow_nil:)
      end

      def normalize_agent_reference!(agent_name, label)
        Identifier.normalize(agent_name, label: "#{label} agent")
      end

      def validate_execution_primitive_conflict!(primitive, declaration: primitive)
        return if @execution_primitive.nil?

        return raise_duplicate_execution_primitive!(declaration) if @execution_primitive == primitive

        raise WorkflowError, "transition cannot declare both #{primitive} and #{@execution_primitive}"
      end

      def raise_duplicate_execution_primitive!(declaration)
        if @execution_primitive == "compute/run" && @execution_declaration != declaration
          raise WorkflowError, "transition cannot declare both compute and run"
        end

        raise WorkflowError, "transition cannot declare #{declaration} more than once"
      end

      def commit_execution_primitive!(primitive, declaration: primitive)
        @execution_primitive = primitive
        @execution_declaration = declaration
      end

      def normalize_fanout_branches!(branches)
        raise WorkflowError, "fan_out branches must be a Hash" unless branches.is_a?(Hash)
        raise WorkflowError, "fan_out requires at least one branch" if branches.empty?

        validate_fanout_size!(branches)

        normalized = branches.each_with_object({}) do |(branch_key, agent_name), map|
          key = normalize_fanout_branch_key!(branch_key)
          agent = normalize_fanout_agent_name!(agent_name, key)
          raise WorkflowError, "fan_out branch #{key.inspect} is duplicated" if map.key?(key)

          map[key] = agent
        end

        validate_distinct_fanout_agents!(normalized)
        normalized.freeze
      end

      def validate_fanout_size!(branches)
        limit = Smith.config.parallel_branch_limit
        return if branches.length <= limit

        raise WorkflowError, "fan_out branch count exceeds configured limit #{limit}"
      end

      def validate_parallel_options!(options)
        return unless options[:parallel] == true

        count = options[:count]
        return if count.nil? || count.respond_to?(:call)
        unless count.is_a?(Integer) && count.positive?
          raise WorkflowError, "parallel branch count must be a positive integer"
        end

        limit = Smith.config.parallel_branch_limit
        return if count <= limit

        raise WorkflowError, "parallel branch count exceeds configured limit #{limit}"
      end

      def normalize_agent_name!(agent_name, label)
        normalize_agent_reference!(agent_name, label).to_sym
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
        return numeric if numeric.between?(0.0, 1.0)

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
        if [String, Symbol].any? { agent_name.is_a?(_1) } && agent_name.to_s.strip.empty?
          raise WorkflowError, "fan_out branch #{branch_key.inspect} must declare an agent"
        end

        normalize_agent_reference!(agent_name, "fan_out branch #{branch_key.inspect}").to_sym
      end

      def validate_distinct_fanout_agents!(branches)
        duplicates = branches.values.tally.select { |_agent, count| count > 1 }.keys
        return if duplicates.empty?

        raise WorkflowError, "fan_out branch agents must be distinct: #{duplicates.map(&:inspect).join(", ")}"
      end

      def normalize_retry_policy!(error_classes, attempts:, backoff:, max_delay:, jitter:)
        error_classes.each do |error_class|
          next if error_class.is_a?(Class) && error_class <= StandardError

          raise WorkflowError, "retry_on error classes must inherit from StandardError"
        end

        ExponentialBackoff.new(
          attempts:,
          base_delay: backoff,
          max_delay:,
          jitter:,
          delay_label: "backoff"
        )
      rescue ArgumentError => e
        raise WorkflowError, "retry_on #{e.message}"
      end

      def normalize_deterministic_routes!(routes)
        return nil if routes.nil?
        raise WorkflowError, "deterministic routes must be an Array" unless routes.is_a?(Array)
        raise WorkflowError, "deterministic routes must not be empty" if routes.empty?

        seen = {}
        routes.each_with_object([]) do |route, list|
          name = normalize_deterministic_route!(route)
          raise WorkflowError, "deterministic route #{name.inspect} is duplicated" if seen.key?(name)

          seen[name] = true
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
