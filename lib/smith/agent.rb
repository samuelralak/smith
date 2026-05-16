# frozen_string_literal: true

require "ruby_llm"

module Smith
  class Agent < RubyLLM::Agent
    # Reserved input names auto-injected by the normalizer into
    # runtime_context. User-side `inputs :name` calls cannot redeclare
    # these names; the override raises Smith::AgentError if they try.
    # The getter merges user-declared inputs WITH reserved so subclasses
    # don't lose reserved names when declaring their own.
    RESERVED_INPUT_NAMES = %i[model_id provider endpoint_mode].freeze

    class << self
      def inherited(subclass)
        super
        subclass.instance_variable_set(:@budget_config, @budget_config)
        subclass.instance_variable_set(:@guardrails_class, @guardrails_class)
        subclass.instance_variable_set(:@output_schema_class, @output_schema_class)
        subclass.instance_variable_set(:@data_volume, @data_volume)
        subclass.instance_variable_set(:@fallback_models_list, @fallback_models_list&.dup)
        subclass.instance_variable_set(:@model_block, @model_block)
        subclass.instance_variable_set(:@registered_name, nil)
      end

      def budget(**opts)
        return @budget_config if opts.empty?

        @budget_config = opts
      end

      def guardrails(klass = nil)
        return @guardrails_class if klass.nil?

        @guardrails_class = klass
      end

      def output_schema(klass = nil)
        return @output_schema_class if klass.nil?

        @output_schema_class = klass
      end

      def data_volume(value = nil)
        return @data_volume if value.nil?

        @data_volume = value
      end

      def fallback_models(*models)
        return @fallback_models_list if models.empty?

        entries = models.flatten.compact.map(&:to_s)
        raise Smith::WorkflowError, "fallback_models entries must not be blank" if entries.any?(&:empty?)

        @fallback_models_list = entries.uniq
      end

      def register_as(name = nil)
        return @registered_name if name.nil?

        @registered_name = name
        Registry.ensure_registered(name.to_sym, self)
      end

      # Extends RubyLLM::Agent.model with a block-form for context-driven
      # resolution at chat-construction time.
      #
      # Static form `model "gpt-5-mini"`:
      #   Stores into @chat_kwargs[:model] via RubyLLM's existing path.
      #   Model id is fixed at class-load time.
      #
      # Block form `model { |context| ... }`:
      #   Stores the block as @model_block. Smith's lifecycle resolves it
      #   at chat-construction time using the workflow's @context (Hash).
      #   Return value must be a non-empty string; non-string / empty / nil
      #   returns surface as Smith::AgentError at the resolution point
      #   (see Smith::Agent::Lifecycle#build_model_chain).
      #
      # Mutually exclusive within a single declaration: passing both a
      # string id and a block raises ArgumentError. Redeclaring with the
      # other form clears the previous setting (static replaces block,
      # block replaces static).
      #
      # Composes with `fallback_models`: resolved primary, then declared
      # fallbacks, in order. Same path as static-form fallback.
      def model(model_id = nil, **options, &block)
        if block
          raise ArgumentError, "model can take a string id OR a block, not both" if model_id || !options.empty?

          @model_block = block
          # Clear any stale `@chat_kwargs[:model]` from a prior static-form
          # declaration. Smith's workflow lifecycle resolves block-form
          # correctly via `build_model_chain` (which checks @model_block
          # first), but RubyLLM's direct `chat()` and `with_rails_chat_record`
          # paths splat `**chat_kwargs` to the constructor; without this
          # delete, those paths would silently use the stale static id.
          # This is the only place Smith mutates a RubyLLM-owned ivar; the
          # mutation is well-scoped (only :model, only on block-form
          # declaration) and matches RubyLLM's own pattern of dup'ing
          # @chat_kwargs through its `inherited` hook.
          @chat_kwargs ||= {}
          @chat_kwargs.delete(:model)
        else
          @model_block = nil
          super
        end
      end

      attr_reader :model_block

      # Whether this agent class has any model configured (static or block).
      # Smith::Workflow::Execution uses this as a precondition for invoking
      # the agent; agents declared without a model are skipped.
      def model_configured?
        !chat_kwargs[:model].nil? || !@model_block.nil?
      end

      # MERGING override: getter always returns user-declared ∪ reserved;
      # setter validates user names against reserved + stores only user
      # names. RubyLLM's bare `@input_names = names` (agent.rb:96) REPLACES;
      # this override prevents subclasses from losing reserved names when
      # they declare their own inputs.
      def inputs(*names)
        if names.empty?
          user = @input_names || []
          return (user + RESERVED_INPUT_NAMES).uniq.freeze
        end

        user_names = names.flatten.map(&:to_sym)
        collisions = user_names & RESERVED_INPUT_NAMES
        if collisions.any?
          raise Smith::AgentError,
                "agent input names #{collisions.inspect} are reserved by Smith. " \
                "Reserved names #{RESERVED_INPUT_NAMES.inspect} are auto-injected by " \
                "Smith::Models::Normalizer into runtime_context. " \
                "Rename your inputs to avoid the collision."
        end

        @input_names = user_names.freeze
      end

      # Closes the `inputs` contract at the chat() boundary AND runs the
      # Smith::Models::Normalizer. Hook lives here (not in
      # Lifecycle#attempt_model) so direct callers like hadithi-xl's
      # InvokeCleaner.chat (which constructs a chat outside the workflow
      # lifecycle) are normalized too. Without this placement, Cleaner's
      # Opus 4.7 adaptive thinking translation would only fire for
      # workflow-driven calls.
      #
      # Single profile lookup: resolved once via Models.find_or_infer and
      # passed through both inject_reserved_inputs and Normalizer.apply!.
      def chat(**kwargs)
        # Resolve model from explicit kwarg first, then fall back to the
        # class-level chat_kwargs[:model] (set by `model "..."`). The
        # explicit kwarg path fires from Lifecycle#attempt_model (passes
        # the resolved primary or fallback model); the chat_kwargs path
        # fires from direct callers like `Agent.chat` with no args.
        model_id = kwargs[:model] || chat_kwargs[:model]
        profile = resolve_profile(model_id)
        kwargs = inject_reserved_inputs(kwargs, profile)
        kwargs = nil_fill_declared_inputs(kwargs)

        llm_chat = super
        Smith::Models::Normalizer.apply!(llm_chat, profile: profile) if profile
        llm_chat
      end

      # Normalizes the |ctx| DSL across RubyLLM's block-form attribute setters.
      #
      # RubyLLM evaluates these blocks via `runtime.instance_exec(&block)`,
      # which sets `self` to the runtime_context but passes NO positional
      # arguments, so `tools do |ctx| ctx.form_kind end` would silently
      # bind `ctx = nil` and crash on the first method call. Smith's `model`
      # block-form already uses `block.call(@context)` (an explicit Hash arg),
      # giving agent authors a uniform `|ctx|` mental model. These overrides
      # carry that convention through to RubyLLM's setters by wrapping any
      # block so `|ctx|` receives the runtime_context AND `self` is still the
      # runtime (preserving RubyLLM's bare-method-dispatch convention for
      # zero-arity blocks).
      #
      # Behavior matrix:
      #   tools do            ... end  (arity 0): preserved as-is; bare method
      #                                            calls dispatch to runtime via
      #                                            instance_exec (RubyLLM idiom)
      #   tools do |ctx|      ... end  (arity 1): wrapped; ctx receives runtime
      #                                            AND self is runtime, so both
      #                                            `ctx.x` and bare `x` work
      #
      # Lambdas with arity 0 are preserved as-is (strict-arity safe). The
      # wrapping path uses Proc semantics, so extra args don't raise.
      def tools(*tools, &block)
        return super unless block

        super(&wrap_runtime_block(block))
      end

      def instructions(text = nil, **prompt_locals, &block)
        return super unless block

        super(text, **prompt_locals, &wrap_runtime_block(block))
      end

      def params(**params_kwargs, &block)
        return super unless block

        super(&wrap_runtime_block(block))
      end

      def headers(**headers_kwargs, &block)
        return super unless block

        super(&wrap_runtime_block(block))
      end

      def schema(value = nil, &block)
        return super unless block

        super(&wrap_runtime_block(block))
      end

      private

      def resolve_profile(model_id)
        return nil unless model_id
        return nil unless defined?(Smith::Models)

        Smith::Models.find_or_infer(model_id)
      end

      def inject_reserved_inputs(kwargs, profile)
        return kwargs unless profile

        reserved = {
          model_id: profile.model_id,
          provider: profile.provider,
          endpoint_mode: profile.endpoint_mode
        }
        # User-provided values win on key collision.
        reserved.merge(kwargs)
      end

      def nil_fill_declared_inputs(kwargs)
        inputs.each_with_object(kwargs.dup) do |name, result|
          result[name] = nil unless result.key?(name)
        end
      end

      def wrap_runtime_block(user_block)
        return user_block if user_block.arity.zero?

        proc do |*|
          runtime = self
          runtime.instance_exec(runtime, &user_block)
        end
      end
    end
  end
end
