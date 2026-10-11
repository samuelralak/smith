# frozen_string_literal: true

require_relative "execution_result_snapshot"
require_relative "message_value_normalizer"

module Smith
  class Workflow
    # Launching the runs of `map`, `call` and `spawn` steps through the
    # host's run launcher, and taking their results when the host resumes
    # the parent. A child's ref is the index of its item; items come from
    # the context (or a callable of it), so a replayed step launches the
    # same children, and the launcher must be idempotent on
    # `(parent_key, ref)`.
    module ChildRunExecution
      STATUSES = %w[succeeded failed].freeze
      RESULT_KEYS = %i[ref status state output].freeze
      private_constant :STATUSES, :RESULT_KEYS

      private

      # Launches the children; returns their results when the launcher ran
      # them itself, else nil (the host resumes the parent later).
      def launch_child_runs(transition, token)
        launcher = Smith.config.run_launcher
        kind = transition.children_config.fetch(:kind)
        raise WorkflowError, "#{kind} needs Smith.config.run_launcher" unless launcher

        children = child_runs(transition).freeze
        unless @persistence_key || (launcher.respond_to?(:inline?) && launcher.inline?)
          raise WorkflowError, "#{kind} starts runs of their own, so it needs a persisted run " \
                               "(run_persisted! or advance_persisted!)"
        end

        results = launcher.launch(children:, parent_key: @persistence_key, await_token: token)
        results if results.is_a?(Array)
      end

      def child_runs(transition)
        config = transition.children_config
        context = snapshot_value(@context)
        child_items(transition).each_with_index.map do |item, index|
          input = child_input(config, item, context)
          ChildRun.new(ref: index, workflow: config.fetch(:workflow), input:,
                       untrusted_keys: (untrusted_context_keys & input.keys).freeze)
        end
      end

      def child_items(transition)
        config = transition.children_config
        return [nil] if config.fetch(:kind) == :call

        items = item_source(config.fetch(:items))
        raise WorkflowError, "#{config[:kind]} items must be an Array" unless items.is_a?(Array)
        return items if items.length <= config.fetch(:max_items)

        raise WorkflowError, "#{config[:kind]} has #{items.length} items, more than its max_items of " \
                             "#{config[:max_items]}"
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
      def deliver_child_results(transition, results)
        config = transition.children_config
        entries = checked_child_results(results, child_items(transition).length, config[:kind])
        fail_on_failed_children!(transition, entries) if config[:on_item_failure] == :fail
        write_wait_payload(transition, collected_child_results(config, entries))
      end

      def fail_on_failed_children!(transition, entries)
        failed = entries.select { _1[:status] == "failed" }
        return if failed.empty?

        raise ChildRunsFailed.new(transition: transition.name, failed_refs: failed.map { _1[:ref] },
                                  total: entries.length)
      end

      # Results the host delivers are checked before the step completes:
      # malformed ones raise to the host and leave the run waiting.
      def check_claimed_child_results!(transition, results)
        checked_child_results(results, child_items(transition).length, transition.children_config[:kind])
      rescue StandardError
        @wait_claimed = false
        raise
      end

      def checked_child_results(results, expected, kind)
        entries = results.is_a?(Array) ? results.map { child_result(_1, kind) } : nil
        unless entries && entries.map { _1[:ref] }.sort == (0...expected).to_a
          raise WorkflowError, "#{kind} results must hold one entry for each of its #{expected} children, by ref"
        end

        entries.sort_by { _1[:ref] }
      end

      def child_result(entry, kind)
        valid = entry.is_a?(Hash) && (entry.keys - RESULT_KEYS).empty? && entry[:ref].is_a?(Integer) &&
                STATUSES.include?(entry[:status]) && (entry[:state].nil? || entry[:state].is_a?(String))
        return entry if valid

        raise WorkflowError, "#{kind} results are { ref:, status: \"succeeded\" | \"failed\", state:, output: }"
      end

      def collected_child_results(config, entries)
        return entries.first[:output] if config[:kind] == :call

        case config[:collect]
        when :outputs then entries.map { _1.slice(*RESULT_KEYS) }
        when :states then entries.map { _1.slice(:ref, :status, :state) }
        else
          failed = entries.count { _1[:status] == "failed" }
          { succeeded: entries.length - failed, failed: }
        end
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
                              .within(:step, @step_count + 1, transition.name.to_s).within(:spawn).key
        launch_child_runs(transition, token)
        nil
      end
    end
  end
end
