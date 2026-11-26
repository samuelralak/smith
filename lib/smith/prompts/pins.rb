# frozen_string_literal: true

module Smith
  module Prompts
    # Internal. One run's pins: the text each named prompt sends, by
    # component id. Resolved when the run starts (or is restored) for every
    # agent its definition names, its nested workflows' included, and for
    # an agent it could not see then (registered behind a block, or called
    # from Ruby inside a step) at its first use; one lock covers every read
    # and pin, so branches never pin twice. A trial's candidate takes a
    # component's place as soon as it is resolved, a pin it was restored or
    # handed down with included. Every pinned text is kept, so a restored
    # run sends exactly the text it started with, never the registry's or a
    # deploy's; its state holds each version and each version's text once.
    # A nested workflow shares its parent's pins; a child run starts from
    # its parent's state. A start walks the transitions of the class and
    # its nested classes once, O(T); reading what was handed down is O(N)
    # in its texts' bytes; a pinned read is O(1).
    class Pins
      SHAPE = "prompt pins map component ids to versions, and each version to its text"
      # The empty Smith::Scope.
      SCOPE = {}.freeze
      private_constant :SHAPE, :SCOPE

      # The trial's candidate the run started or was restored with.
      attr_reader :candidate

      # `handed`: a run's saved state or what its parent handed down, or nil.
      def initialize(handed, candidate)
        @pinned = pinned!(handed)
        @candidate = candidate
        @settled = {}
        @defaults = {}
        @walked = {}.compare_by_identity
        @lock = Mutex.new
      end

      def discover(workflow_class)
        @lock.synchronize { walk(workflow_class) }
        self
      end

      # What this run sends for the agent's named prompt.
      def prompt_for(agent_class) = @lock.synchronize { resolved(agent_class.smith_prompt) }

      # {"versions" => {id => version}, "texts" => {version => text}}, or nil
      # while nothing is pinned.
      def state
        @lock.synchronize do
          next if @pinned.empty?

          { "versions" => @pinned.transform_values(&:version),
            "texts" => @pinned.each_value.to_h { [_1.version, _1.text] } }
        end
      end

      def prompts = @lock.synchronize { @pinned.dup.freeze }

      private

      # What was handed over, every text read back and checked against its
      # version; no text but a pinned version's.
      def pinned!(handed)
        return {} if handed.nil? || handed == {}

        versions, texts = parts(handed)
        pinned = versions.to_h { |id, version| pin(id, version, texts) }
        raise SerializationError, SHAPE unless pinned.each_value.map(&:version).uniq.size == texts.size

        pinned
      end

      # [versions, texts], from {"versions" =>, "texts" =>}, String keys or
      # Symbol ones.
      def parts(handed)
        versions, texts = keyed(handed).values_at("versions", "texts") if handed.is_a?(Hash) && handed.size == 2
        valid = versions.is_a?(Hash) && texts.is_a?(Hash) && versions.size <= MAX_COMPONENTS
        raise SerializationError, SHAPE unless valid

        [versions, keyed(texts)]
      end

      def keyed(hash) = hash.transform_keys(&:to_s)

      # A component's pinned text, as a Prompt that is its version.
      def pin(id, version, texts)
        prompt = Prompt.new(id.is_a?(Symbol) ? id.name : id, texts[version])
        raise SerializationError, SHAPE unless prompt.version == version

        [prompt.component_id, prompt]
      rescue PromptInvalid
        raise SerializationError, SHAPE
      end

      def walk(root)
        stack = [root]
        until stack.empty?
          klass = stack.pop
          next if @walked.key?(klass)

          @walked[klass] = true
          (klass.instance_variable_get(:@transitions) || {}).each_value do |transition|
            Workflow::Transition.agent_references(transition).each { pin_agent(_1.last) }
            stack << transition.workflow_class if transition.workflow_class
          end
        end
      end

      # An agent the registry holds as a class. One registered behind a
      # block is not called here: it is pinned at its first use.
      def pin_agent(name)
        default = Agent::Registry.binding_for(name)&.fetch(:agent_class)&.smith_prompt
        resolved(default) if default
      end

      def resolved(default)
        known!(default)
        id = default.component_id
        return @pinned.fetch(id) if @settled.key?(id)

        @pinned[id] = text_for(default).tap { @settled[id] = true }
      end

      # Two agents may share a component only with one text.
      def known!(default)
        seen = (@defaults[default.component_id] ||= default)
        return if seen.version == default.version

        raise PromptInvalid, "#{default.component_id} is declared with two different texts"
      end

      # The resolution order: the trial's candidate, the run's pin, the
      # registry's active version, the default.
      def text_for(default)
        id = default.component_id
        return default.with_text(@candidate[id]) if @candidate.key?(id)
        return @pinned[id] if @pinned.key?(id)

        active = Smith.config.prompt_registry&.active(component_id: id, scope: SCOPE)
        active.nil? ? default : default.with_text(active)
      end
    end
  end
end
