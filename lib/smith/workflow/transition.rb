# frozen_string_literal: true

require_relative "../tool_capture_failed"

module Smith
  class Workflow
    class Transition
      attr_reader :name, :from, :to, :agent_name, :agent_opts, :success_transition, :failure_transition,
                  :router_config, :workflow_class, :optimization_config, :orchestrator_config,
                  :fanout_config, :retry_config, :deterministic_block, :deterministic_kind,
                  :deterministic_routes, :deterministic_fallthrough, :await_config, :timeout_transition,
                  :step_input, :output_to

      def initialize(name, from:, to:, &)
        @name = own_identifier(name)
        @from = own_identifier(from, allow_nil: true)
        @to = own_identifier(to)
        instance_eval(&) if block_given?
        validate_child_run_controls!
        validate_durable_retry!
        validate_timeout_route!
      end

      # Waits, bounded by a required timeout, for an event the host delivers
      # with `Workflow.resume!`, writing its payload to the context key
      # `into:`. The optional block runs on entry with an AwaitStep and may
      # send the request the event answers, or finish at once with
      # `resolve!`. `timeout:` is seconds, or a callable of the context
      # returning seconds; past it, `expire_wait!` takes `on_timeout`.
      def await(event, into:, timeout:, &block)
        validate_execution_primitive_conflict!("await")
        raise WorkflowError, "await into: must be a Symbol context key" unless into.is_a?(Symbol)

        @await_config = {
          kind: :await, event: Identifier.normalize(event, label: "await event"), into:,
          timeout: wait_seconds!(timeout, "await timeout:"), block:
        }.freeze
        commit_execution_primitive!("await")
      end

      # Continues to `to:` no earlier than `seconds` after the step is
      # entered (seconds, or a callable of the context returning seconds),
      # when the host calls `expire_wait!`.
      def delay(seconds)
        validate_execution_primitive_conflict!("delay")
        @await_config = { kind: :delay, event: nil, into: nil, timeout: wait_seconds!(seconds, "delay"), block: nil }
                        .freeze
        commit_execution_primitive!("delay")
      end

      # The transition an `await` takes when its deadline passes.
      def on_timeout(transition_name)
        @timeout_transition = own_identifier(transition_name)
      end

      def awaits? = !@await_config.nil?

      def delay? = @await_config&.fetch(:kind) == :delay

      # `input:` (on every agent primitive) is a callable of a copy of the
      # context returning the step's messages, which replace the session
      # transcript for this step. `output_to:` names the context key the
      # step's output is written to, instead of the transcript.
      def execute(agent_name, input: nil, output_to: nil, **opts)
        validate_execution_primitive_conflict!("execute")

        normalized_agent = normalize_agent_reference!(agent_name, "agent")
        validate_parallel_options!(opts)
        assign_step_io!(input, output_to)

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

      def route(agent_name, routes:, confidence_threshold:, fallback:, input: nil)
        validate_execution_primitive_conflict!("route")
        assign_step_io!(input, nil)
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
                   on_threshold: :raise,
                   input: nil,
                   output_to: nil)
        validate_execution_primitive_conflict!("optimize")
        assign_step_io!(input, output_to)
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

      def orchestrate(input: nil, output_to: nil, **opts)
        validate_execution_primitive_conflict!("orchestrate")
        assign_step_io!(input, output_to)
        validate_orchestrate_controls!(opts)
        config = opts.merge(
          orchestrator: normalize_agent_reference!(opts.fetch(:orchestrator), "orchestrator"),
          worker: normalize_agent_reference!(opts.fetch(:worker), "orchestrator worker")
        ).freeze

        @orchestrator_config = config
        commit_execution_primitive!("orchestrate")
      end

      def fan_out(branches:, input: nil, output_to: nil)
        validate_execution_primitive_conflict!("fan_out")
        assign_step_io!(input, output_to)

        normalized = normalize_fanout_branches!(branches)
        @fanout_branch_lookup = normalized.to_h do |key, agent|
          [key.to_s.freeze, [key, agent].freeze]
        end.freeze
        config = { branches: normalized }.freeze

        @fanout_config = config
        commit_execution_primitive!("fan_out")
      end
      alias fanout fan_out

      # `new_idempotency_key_on:` names errors that show an attempt's
      # requests took no effect (a refusal, not a timeout): the attempts
      # after one of them use new idempotency keys. Every other retry keeps
      # the step's keys. It is refused on a transition whose failures can
      # come from several steps or branches (a nested workflow, parallel or
      # fan-out branches, an optimizer or an orchestrator), where one error
      # cannot speak for every request of the attempt.
      #
      # `durable: true` waits out each backoff as a wait of the run (kind
      # `:retry`) instead of sleeping in the worker: the host wakes it with
      # `expire_wait!` and continues the run, which makes the next attempt
      # under the recorded attempt number and key generation.
      # rubocop:disable Metrics/ParameterLists
      def retry_on(*error_classes, attempts:, backoff: 0, max_delay: nil, jitter: 0, new_idempotency_key_on: [],
                   durable: false)
        policy = normalize_retry_policy!(error_classes, attempts:, backoff:, max_delay:, jitter:)
        new_key_classes = normalize_new_idempotency_key_on!(new_idempotency_key_on, error_classes)
        validate_durable_policy!(durable, policy)

        config = {
          error_classes: error_classes.freeze,
          attempts: policy.attempts,
          backoff: policy.base_delay,
          max_delay: policy.max_delay,
          jitter: policy.jitter
        }
        config[:new_idempotency_key_on] = new_key_classes if new_key_classes.any?
        config[:durable] = true if durable
        @retry_config = config.freeze
        reject_new_idempotency_key_on_composite!
      end
      # rubocop:enable Metrics/ParameterLists

      def durable_retry? = @retry_config&.fetch(:durable, false) == true

      def validate_durable_policy!(durable, policy)
        raise WorkflowError, "retry_on durable: must be true or false" unless [true, false].include?(durable)
        return unless durable && !(policy.attempts > 1 && policy.base_delay.positive?)

        raise WorkflowError, "retry_on durable: needs at least 2 attempts and a positive backoff, so it has a wait"
      end
      private :validate_durable_policy!

      # A step that waits (an await, delay, map or call), launches runs of
      # its own (a spawn), or waits between attempts (a durable retry).
      def waits_or_launches? = awaits? || child_runs? || durable_retry?

      %i[compute run].each do |method_name|
        define_method(method_name) do |routes: nil, fallthrough: false, &block|
          validate_execution_primitive_conflict!("compute/run", declaration: method_name.to_s)
          raise WorkflowError, "#{method_name} requires a block" unless block

          normalized_routes = normalize_deterministic_routes!(routes)
          validate_deterministic_fallthrough!(fallthrough, normalized_routes)

          @deterministic_block = block
          @deterministic_kind = method_name
          @deterministic_routes = normalized_routes
          @deterministic_fallthrough = fallthrough
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

      # Whether the step runs an agent: `execute`, `route`, `fan_out`,
      # `optimize` or `orchestrate`.
      def agent_step?
        !agent_name.nil? || optimized? || orchestrated? || fanout?
      end

      private

      def assign_step_io!(input, output_to)
        raise WorkflowError, "input: must be a callable of the context" unless input.nil? || input.respond_to?(:call)
        raise WorkflowError, "output_to: must be a Symbol context key" unless output_to.nil? || output_to.is_a?(Symbol)

        @step_input = input
        @output_to = output_to
      end

      def wait_seconds!(value, label)
        return value if value.respond_to?(:call)
        return value if (value.is_a?(Integer) || (value.is_a?(Float) && value.finite?)) && value.positive?

        raise WorkflowError, "#{label} must be a positive number of seconds or a callable returning one"
      end

      # An await must say where its timeout goes: past its deadline it takes
      # `on_timeout`, or else `on_failure` with Smith::WaitTimedOut. Without
      # either, an expired wait could never end.
      # A durable retry waits between attempts, so its step must be one a
      # run can wait in: not a step that waits itself, nor one whose
      # branches keep durable state of their own.
      def validate_durable_retry!
        return unless durable_retry? && (awaits? || parallel? || fanout? || optimized? || orchestrated?)

        raise WorkflowError, "retry_on durable: is not available on await, delay, parallel, fan_out, optimize or " \
                             "orchestrate steps"
      end

      def validate_timeout_route!
        if @timeout_transition
          return if @await_config && !delay?

          raise WorkflowError, "on_timeout requires an await step"
        end
        return unless @await_config && !delay? && @failure_transition.nil?

        raise WorkflowError, "an await step must declare on_timeout or on_failure for its deadline"
      end

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
        reject_new_idempotency_key_on_composite!
      end

      def several_step_execution? = nested? || parallel? || fanout? || optimized? || orchestrated?

      def reject_new_idempotency_key_on_composite!
        return unless @retry_config&.key?(:new_idempotency_key_on) && several_step_execution?

        raise WorkflowError,
              "retry_on new_idempotency_key_on: cannot be declared on a nested workflow, parallel, fan_out, " \
              "optimize or orchestrate transition, where one error cannot speak for every request of the attempt"
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
        reject_retry_forbidden!(error_classes)

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

      def normalize_new_idempotency_key_on!(classes, retried_classes)
        unless classes.is_a?(Array) && classes.all? { |error_class| standard_error_class?(error_class) }
          raise WorkflowError, "retry_on new_idempotency_key_on: must be an Array of StandardError classes"
        end

        if classes.uniq.size != classes.size
          raise WorkflowError, "retry_on new_idempotency_key_on: lists a class more than once"
        end

        reject_retry_forbidden!(classes, context: "move to new idempotency keys after")
        reject_unretried_new_key_classes!(classes, retried_classes)
        classes.dup.freeze
      end

      def standard_error_class?(value) = value.is_a?(Class) && value <= StandardError

      # With no error classes the policy retries whatever Smith classifies
      # retryable, which cannot be checked here.
      def reject_unretried_new_key_classes!(classes, retried_classes)
        return if retried_classes.empty?

        unretried = classes.find { |error_class| retried_classes.none? { |retried| error_class <= retried } }
        return unless unretried

        raise WorkflowError, "retry_on new_idempotency_key_on: lists #{unretried.name || unretried.inspect}, " \
                             "which this policy does not retry"
      end

      def reject_retry_forbidden!(error_classes, context: "retry")
        forbidden = error_classes.find { |error_class| Smith::Errors.retry_forbidden_class?(error_class) }
        return unless forbidden

        label = forbidden.name || "an anonymous terminal tool-evidence error class"
        raise WorkflowError, "retry_on cannot #{context} #{label} because the tool outcome may be uncertain"
      end

      # `fallthrough: true` lets a step that declares `routes:` finish without
      # routing, taking `on_success` or the first transition from its target
      # state. It means nothing without `routes:`.
      def validate_deterministic_fallthrough!(fallthrough, routes)
        raise WorkflowError, "fallthrough must be true or false" unless [true, false].include?(fallthrough)
        raise WorkflowError, "fallthrough: true requires routes:" if fallthrough && routes.nil?
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
