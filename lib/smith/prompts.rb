# frozen_string_literal: true

module Smith
  autoload :Prompt, File.expand_path("prompt", __dir__)
  autoload :ContentIdentity, File.expand_path("content_identity", __dir__)

  # Experimental. The prompt seam (plan 5.2). An agent declares its
  # instructions as a named prompt (Smith::Prompt), and every run resolves
  # what it sends for it in one order: the trial's candidate, the run's pin,
  # the prompt registry's active version, the default in the code or file.
  # A run pins its components when it starts, for every agent its
  # definition names (its nested workflows' too), and an agent it could not
  # see then at its first use, and keeps each pinned text in its saved
  # state, so a run that waits for days sends what it started with whatever
  # moves or changes meanwhile; its branches and nested workflows share the
  # pins, and a child run starts from them. An agent called from Ruby inside
  # one of the run's steps (a compute block, a tool) sends what the run
  # sends for it. Usage entries, :provider_call traces and attempt
  # observations carry the versions an attempt was built to send
  # (`components`).
  #
  #   Smith.config.prompt_registry = registry            # optional
  #   Smith::Prompts.components(Workflow)                # => {"triage.rules" => #<Smith::Prompt>}
  #   Smith::Prompts.with_candidate("triage.rules" => text) { Workflow.new(context:).run! }
  #
  # A registry answers, with a Smith::Scope (empty in this release: a
  # code-defined agent is the host's own), the text in force, or nil for
  # the default:
  #
  #   active(component_id:, scope:)
  #
  # A version is its text's SHA-256, worked out by Smith. With no registry
  # the default is in force: the files in the repo.
  #
  # The candidate scope is fiber-local, as a trial's attribution is
  # (Smith::Attribution): a run is a trial's when it is built or restored
  # in the block, and then every thread Smith starts for it sends what it
  # sends, while a fiber or thread a host starts in the block, or a pool's
  # thread made there, never takes the trial's text with it.
  #
  # Loaded by `require "smith"`, alone: Smith::Prompt loads when first
  # named, the pins when a run first starts; until an agent declares a
  # named prompt a run's pins stay empty and nothing is saved, stamped or
  # asked of a registry.
  module Prompts
    autoload :Pins, File.expand_path("prompts/pins", __dir__)
    autoload :Stamp, File.expand_path("prompts/stamp", __dir__)

    CANDIDATE = :smith_prompt_candidate
    INHERITED = :smith_inherited_prompt_pins
    RUNNING = :smith_running_prompt_pins
    SENDING = :smith_prompt_sending
    # The most components a run pins, or a stamp lists.
    MAX_COMPONENTS = 1_000
    NONE = {}.freeze
    private_constant :CANDIDATE, :INHERITED, :RUNNING, :SENDING, :MAX_COMPONENTS, :NONE

    @declared = false

    class << self
      # Runs the block with `texts` ({component_id => text}) as the trial's
      # candidate, over any candidate around it: a run built or restored in
      # it, in this fiber, sends each text in place of its component's, and
      # is refused (PromptInvalid) before anything runs unless the text
      # keeps the component's fill-in fields. The run keeps it, so its
      # branches, its nested workflows and the children it builds send it
      # on whatever thread Smith runs them.
      def with_candidate(texts)
        outer = Thread.current[CANDIDATE]
        candidate = (outer || NONE).merge(candidate!(texts)).freeze
        begin
          Thread.current[CANDIDATE] = candidate
          yield
        ensure
          Thread.current[CANDIDATE] = outer
        end
      end

      # The named prompts a run of `workflow_class` would pin now (the
      # registry's active versions, else the defaults), by component id,
      # its nested workflows' included: what a tuner swaps.
      def components(workflow_class) = Pins.new(nil, NONE).discover(workflow_class).prompts

      private

      # Whether any agent in this process declares a named prompt: until
      # one does, a starting run has nothing to discover.
      def declared? = @declared

      # For the agent DSL: whether `value` is a named prompt, which exists
      # only once Smith::Prompt has loaded.
      def prompt?(value) = !value.nil? && !Smith.autoload?(:Prompt) && value.is_a?(Smith::Prompt)

      # The instructions block RubyLLM evaluates for an agent that declares
      # `prompt`.
      def declare(agent_class, prompt, prompt_locals, block)
        raise ArgumentError, "a named prompt takes no prompt locals or block" unless prompt_locals.empty? && !block

        @declared = true
        proc { Prompts.__send__(:instructions, prompt, agent_class, self) }
      end

      # The instructions text: what Smith's call is sending for the agent,
      # else what the run whose step this is sends for it (a call from Ruby
      # inside the step), else the default; filled in from the agent's
      # declared inputs, which RubyLLM gives the block's runtime as methods.
      def instructions(default, declarer, runtime)
        sending = Thread.current[SENDING]
        prompt, agent_class =
          if sending&.first&.component_id == default.component_id then sending
          else [Thread.current[RUNNING]&.prompt_for(declarer) || default, declarer]
          end
        prompt.render(prompt.fields.to_h { [_1, input(runtime, agent_class, prompt, _1)] })
      end

      # A starting run's pins: its parent's, shared, for a nested workflow;
      # else new ones, from what a child run was handed.
      def start(workflow_class)
        inherited = take_inherited
        pins = inherited.is_a?(Pins) ? inherited : Pins.new(inherited, candidate)
        discovered(pins, workflow_class)
      end

      # A restored run's pins, from its saved state (nil for a run saved
      # before it had any, which pins what it names now).
      def restored(workflow_class, stored) = discovered(Pins.new(stored, candidate), workflow_class)

      # The saved state's entry, only once something is pinned.
      def state(pins)
        pinned = pins&.state
        pinned ? { prompt_pins: pinned } : NONE
      end

      # What a child run starts from.
      def handed_down(pins) = pins&.state || NONE

      # Builds a nested workflow (its parent's pins, shared) or a child run
      # (what its parent handed down) with them in force.
      def inheriting(source)
        outer = Thread.current[INHERITED]
        Thread.current[INHERITED] = source
        yield
      ensure
        Thread.current[INHERITED] = outer
      end

      # Runs one of the run's steps with its pins in force, for an agent
      # called from Ruby inside it.
      def running(pins)
        outer = Thread.current[RUNNING]
        Thread.current[RUNNING] = pins
        yield
      ensure
        Thread.current[RUNNING] = outer
      end

      # Runs the block (an attempt's chat construction) with the prompt
      # this run sends for the agent in force for its instructions, and
      # yields it the attempt's version stamp, [{id:, version:}]: worked out
      # once, from the text resolved for it. An agent without a named
      # prompt is stamped with the components its class gives (a
      # definition's), or nil.
      def sending(pins, agent_class)
        default = named(agent_class)
        return yield(Stamp.given(agent_class)) unless default

        prompt = pins&.prompt_for(agent_class) || default
        outer = Thread.current[SENDING]
        begin
          Thread.current[SENDING] = [prompt, agent_class].freeze
          yield Stamp.of(prompt)
        ensure
          Thread.current[SENDING] = outer
        end
      end

      # A component id as a Hash key: a String, or a Symbol a host wrote.
      def key?(id) = id.is_a?(String) || id.is_a?(Symbol)

      # A stand-in agent class without the reader declares none.
      def named(agent_class) = agent_class.respond_to?(:smith_prompt) ? agent_class.smith_prompt : nil

      # The candidate a run starts or is restored with: the scope in force,
      # over the candidate of the run whose step builds it (an inline
      # child's parent).
      def candidate
        scoped = Thread.current[CANDIDATE]
        running = Thread.current[RUNNING]&.candidate
        return scoped || running || NONE unless scoped && running

        running.merge(scoped).freeze
      end

      def discovered(pins, workflow_class) = @declared ? pins.discover(workflow_class) : pins

      def take_inherited
        source = Thread.current[INHERITED]
        Thread.current[INHERITED] = nil if source
        source
      end

      def input(runtime, agent_class, prompt, field)
        return runtime.public_send(field) if agent_class.inputs.include?(field.to_sym)

        raise WorkflowError, "named prompt #{prompt.component_id} fills in {{#{field}}}, which is not an input of " \
                             "the agent; declare it with `inputs`"
      end

      def candidate!(texts)
        valid = texts.is_a?(Hash) && texts.all? { |id, text| key?(id) && text.is_a?(String) }
        raise ArgumentError, "a candidate maps component ids to their texts" unless valid

        texts.to_h { |id, text| [id.to_s.freeze, text.dup.freeze] }
      end
    end
  end
end
