# frozen_string_literal: true

require_relative "execution_result_snapshot"
require_relative "message_value_normalizer"

module Smith
  class Workflow
    # Launching the runs of `map`, `call` and `spawn` steps through the
    # host's run launcher, and taking their results when the host resumes
    # the parent. A child's ref is the index of its item; items come from
    # the context (or a callable of it), so a replayed step launches the
    # same children under the same keys, and the launcher must be
    # idempotent on each child's `key`.
    module ChildRunExecution
      MAX_LAUNCH_BYTES = 4 * ExecutionResultSnapshot::MAX_BYTES
      private_constant :MAX_LAUNCH_BYTES

      private

      # Launches the children; returns their results when the launcher runs
      # them itself (`inline?`), else nil (the host resumes the parent
      # later), whatever the launcher returned.
      def launch_child_runs(transition, token)
        launcher = Smith.config.run_launcher
        kind = transition.children_config.fetch(:kind)
        raise WorkflowError, "#{kind} needs Smith.config.run_launcher" unless launcher

        children = child_runs(transition, token).freeze
        unless @persistence_key || inline_launcher?(launcher)
          raise WorkflowError, "#{kind} starts runs of their own, so it needs a persisted run " \
                               "(run_persisted! or advance_persisted!)"
        end

        @launched_children = children.length
        return [] if children.empty?

        results = launcher.launch(children:, parent_key: @persistence_key, await_token: token)
        return unless inline_launcher?(launcher)
        return results if results.is_a?(Array)

        raise WorkflowError, "a run launcher whose inline? is true must return the children's results"
      end

      def inline_launcher?(launcher) = launcher.respond_to?(:inline?) && launcher.inline? == true

      def child_runs(transition, token)
        config = transition.children_config
        context = snapshot_value(@context)
        bytes = 0
        child_items(transition).each_with_index.map do |item, index|
          input = child_input(config, item, context)
          bytes = check_launch_size!(bytes + JSON.generate(input).bytesize, config[:kind])
          child_run(config, token, index, input)
        end
      end

      def child_run(config, token, ref, input)
        ChildRun.new(ref:, key: ChildRun.key_for(token, ref), workflow: config.fetch(:workflow), input:,
                     untrusted_keys: (untrusted_context_keys & input.keys).freeze,
                     artifact_namespaces: child_artifact_namespaces)
      end

      # The inputs of one step's children together are bounded, as one
      # step's result is, four times over; checked as each is built.
      def check_launch_size!(bytes, kind)
        return bytes if bytes <= MAX_LAUNCH_BYTES

        raise WorkflowError, "#{kind} inputs come to more than #{MAX_LAUNCH_BYTES} bytes"
      end

      def child_items(transition)
        config = transition.children_config
        return [nil] if config.fetch(:kind) == :call

        source = config.fetch(:items)
        check_items_persisted!(source, config[:kind])
        items = item_source(source)
        raise WorkflowError, "#{config[:kind]} items must be an Array" unless items.is_a?(Array)
        return items if items.length <= config.fetch(:max_items)

        raise WorkflowError, "#{config[:kind]} has #{items.length} items, more than its max_items of " \
                             "#{config[:max_items]}"
      end

      # A persisted run takes its children's results after a restore, which
      # needs the items key the step launched from.
      def check_items_persisted!(source, kind)
        return unless @persistence_key && source.is_a?(Symbol)

        keys = resolve_persist_keys
        persisted = keys.nil? || (keys == :auto ? @persisted_keys.include?(source) : keys.include?(source))
        raise WorkflowError, "#{kind} items key #{source.inspect} must be persisted" unless persisted
      end

      def item_source(source) = source.respond_to?(:call) ? source.call(snapshot_value(@context)) : @context[source]

      # The child's whole context: a Hash, JSON-shaped and bounded, in the
      # context's key shape.
      def child_input(config, item, context)
        input = config.fetch(:input)
        raw = config.fetch(:kind) == :call ? input.call(context) : input.call(item, context)
        raise WorkflowError, "#{config[:kind]} input: must return a Hash" unless raw.is_a?(Hash)

        ContextKeys.normalize(MessageValueNormalizer.new(raw, label: "child run input").call).freeze
      end

      # Checks the results against the children the step launched (one per
      # ref, each succeeded or failed), then, unless a failed child fails
      # the step, writes them to `into:` as the step collects them.
      def deliver_child_results(transition, results, expected = expected_children(transition))
        config = transition.children_config
        entries = checked_child_results(results, expected, config[:kind])
        fail_on_failed_children!(transition, entries) if config[:on_item_failure] == :fail
        write_wait_payload(transition, collected_child_results(config, entries))
      end

      def fail_on_failed_children!(transition, entries)
        failed = entries.select { _1[:status] == "failed" }
        return if failed.empty?

        raise ChildRunsFailed.new(transition: transition.name, failed_refs: failed.map { _1[:ref] },
                                  total: entries.length)
      end

      # How many children the step launched: as the stored wait records it,
      # or, for a delivery that comes before the wait is stored, its items.
      def expected_children(transition)
        stored = @awaiting && @awaiting["children"]
        stored.is_a?(Integer) ? stored : child_items(transition).length
      end

      # Child results are larger than a session message: a map's outputs
      # together are bounded like a step's result.
      def child_results_payload(payload)
        bound = ExecutionResultSnapshot::MAX_BYTES
        ContextKeys.normalize(MessageValueNormalizer.new(payload, label: "child run results", max_bytes: bound).call)
      end

      # A spawn launches and the step completes.
      def execute_spawn_step(transition)
        check_deadline!
        namespace = ArtifactIntegration.instance_method(:execution_namespace).bind_call(self)
        token = IdempotencyKey.__send__(:root_scope, namespace)
                              .within(:step, @step_count + 1, self.class.transition_key_name(transition.name))
                              .within(:spawn).key
        launch_child_runs(transition, token)
        nil
      end
    end
  end
end
