# frozen_string_literal: true

require_relative "provider_options"

module Smith
  # Run credentials in a workflow class's runtime readiness (additions
  # design 3.4 and 3.6), for a class that declares `provider_credentials` or
  # under Smith.config.require_run_credentials, so a class without them
  # reads as before. What would let a key fall through, or reach a log:
  # - :run_credentials_required (fail-closed): the class asks an agent and
  #   declares none (a class that asks none, an abstract base or a
  #   compute-only workflow, needs none; a parent's report leaves it out for
  #   its nested and child classes, each judged on its own: ruled
  #   2026-11-23);
  # - :debug_logging_with_run_credentials: RubyLLM's global logger writes
  #   response bodies (DEBUG, or log_stream_debug), a warning, refused when
  #   fail-closed;
  # - :instrumenter_with_run_credentials: run_credentials_instrumenter :keep;
  # - :global_provider_keys_present (fail-closed): a key in RubyLLM's global
  #   configuration, which a host's own RubyLLM calls would use;
  # - :agent_context_with_run_credentials: an agent of the run (a nested
  #   workflow without its own declaration included) sets its own RubyLLM
  #   context or declares an input named context, which would replace the
  #   run's;
  # - :item_chooses_run_credentials: a nested class takes its own scope from
  #   the key its items are given (item_to), which the run refuses: item
  #   data, a model's answer perhaps, never chooses whose keys a run uses;
  # - :ambient_provider_credentials_present (fail-closed): credentials a
  #   cloud SDK would find in the environment or on the machine, which no
  #   run sends but a host's own calls could.
  # O(T + A) for T reachable transitions and A agents.
  class RunCredentialsReadiness
    Diagnostic = Workflow::Graph::Diagnostic
    private_constant :Diagnostic

    def self.declared?(workflow_class)
      workflow_class.respond_to?(:provider_credentials) && !workflow_class.provider_credentials.nil?
    end

    # Whether a run of the class asks an agent on its own credentials: a
    # reachable step does, or a nested workflow's without a declaration of
    # its own. A child run is a run of its own, so it is not counted.
    def self.asks_agents?(workflow_class, seen = Set[])
      return false if seen.include?(workflow_class) || !workflow_class.respond_to?(:graph)

      seen << workflow_class
      workflow_class.graph.reachable_transitions.any? do |transition|
        nested = transition.nested? && !declared?(transition.workflow_class)
        transition.agent_step? || (nested && asks_agents?(transition.workflow_class, seen))
      end
    end

    def initialize(graph)
      @graph = graph
      @klass = graph.workflow_class
      @fail_closed = Smith.config.require_run_credentials
    end

    def to_a
      declared = self.class.declared?(@klass)
      needs = @fail_closed && !declared && self.class.asks_agents?(@klass)
      [*(required if needs), *Worker.diagnostics(name, declared:, fail_closed: @fail_closed),
       *(agent_contexts if declared), *items_choosing]
    end

    # What the worker holds, the same for every class: RubyLLM's logging, a
    # kept instrumenter, keys in RubyLLM's global configuration and cloud
    # credentials on the machine.
    module Worker
      module_function

      def diagnostics(name, declared:, fail_closed:)
        [*logging(name, fail_closed), *(instrumented(name) if declared),
         *(global_keys(name) if fail_closed && ProviderOptions.global_secrets?), *(ambient(name) if fail_closed)]
      end

      def logging(name, fail_closed)
        why = ProviderOptions.body_logging
        return [] unless why

        [Diagnostic.new(severity: fail_closed ? :error : :warning, code: :debug_logging_with_run_credentials,
                        target: name,
                        message: "RubyLLM's global logger writes response bodies (#{why}), which may echo part of a " \
                                 "run's key.",
                        suggestion: "Run RubyLLM's logger at INFO or above (config.logger's level, or log_level), " \
                                    "with log_stream_debug off.")]
      end

      def instrumented(name)
        return [] unless Smith.config.run_credentials_instrumenter == :keep

        [Diagnostic.new(severity: :warning, code: :instrumenter_with_run_credentials, target: name,
                        message: "Smith.config.run_credentials_instrumenter is :keep: RubyLLM's instrumentation " \
                                 "subscribers see each credentialed request, its error and headers included.",
                        suggestion: "Leave run_credentials_instrumenter :off where runs use their own keys.")]
      end

      def global_keys(name)
        [Diagnostic.new(severity: :warning, code: :global_provider_keys_present, target: name,
                        message: "RubyLLM's global configuration holds a provider key, which a host's own RubyLLM " \
                                 "calls, outside Smith's agents, would send.",
                        suggestion: "Leave provider keys out of RubyLLM's global configuration.")]
      end

      def ambient(name)
        found = ProviderOptions.ambient_credentials
        return [] if found.empty?

        [Diagnostic.new(severity: :warning, code: :ambient_provider_credentials_present, target: name,
                        message: "Credentials a cloud SDK finds on its own are present (#{found.join(", ")}): no " \
                                 "run sends them, as each names its provider's credential, but a host's own " \
                                 "calls could.",
                        suggestion: "Keep the worker's own cloud credentials out of the process that serves runs.")]
      end
    end
    private_constant :Worker

    private

    def name = @klass.name || @klass.inspect

    def required
      [Diagnostic.new(severity: :error, code: :run_credentials_required, target: name,
                      message: "#{name} declares no provider_credentials, and Smith.config.require_run_credentials " \
                               "refuses its provider requests.",
                      suggestion: "Declare provider_credentials on #{name} or its base class, scoped by a key " \
                                  "each run is given.")]
    end

    # A nested class scoped by the key its items are given (item_to).
    def items_choosing
      @graph.reachable_transitions.filter_map do |transition|
        key = @klass.find_transition(transition.name)&.nested_items&.fetch(:item_to)
        scoped = key && transition.workflow_class.smith_provider_credentials_scope_keys.include?(key)
        item_chooses(transition, key) if scoped
      end
    end

    def item_chooses(transition, key)
      Diagnostic.new(severity: :error, code: :item_chooses_run_credentials, transition: transition.name,
                     target: transition.workflow_class.name.to_s,
                     message: "Transition #{transition.name.inspect} gives each item to #{key.inspect}, from which " \
                              "its nested class takes its provider_credentials scope; the run refuses it.",
                     suggestion: "Scope the nested class by a key of the run's trusted context, not the item's.")
    end

    def agent_contexts
      @graph.reachable_transitions.flat_map do |transition|
        agents(transition, Set[@klass]).uniq.filter_map { replaced_context(transition, _1) }
      end
    end

    def agents(transition, seen)
      [*step_agents(transition), *(nested_agents(transition.workflow_class, seen) if transition.nested?)].compact
    end

    def step_agents(transition)
      return transition.fanout_config.fetch(:branches).values if transition.fanout?
      return transition.optimization_config.values_at(:generator, :evaluator) if transition.optimized?
      return transition.orchestrator_config.values_at(:orchestrator, :worker) if transition.orchestrated?

      [transition.agent_name]
    end

    # A nested workflow without its own declaration sends on this run's.
    def nested_agents(workflow_class, seen)
      return [] if seen.include?(workflow_class) || self.class.declared?(workflow_class) ||
                   !workflow_class.respond_to?(:graph)

      seen << workflow_class
      workflow_class.graph.reachable_transitions.flat_map { agents(_1, seen) }
    end

    def replaced_context(transition, agent)
      agent_class = Agent::Registry.binding_for(agent)&.fetch(:agent_class)
      return unless agent_class.respond_to?(:context)
      return unless agent_class.context || Array(agent_class.inputs).include?(:context)

      Diagnostic.new(severity: :error, code: :agent_context_with_run_credentials, transition: transition.name,
                     target: agent,
                     message: "Agent #{agent.inspect} sets its own RubyLLM context or declares an input named " \
                              "context, which would replace the run's credentials.",
                     suggestion: "Drop the agent's context (and any input named context); the run's credentials " \
                                 "give its chats theirs.")
    end
  end
end
