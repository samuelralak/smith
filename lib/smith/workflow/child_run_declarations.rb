# frozen_string_literal: true

module Smith
  class Workflow
    class Transition
      # Steps that start other workflows as runs of their own, through the
      # host's run launcher (`Smith.config.run_launcher`):
      #
      #   map :section_ids, workflow: Sections::Review, max_items: 500, timeout: 6 * 3600,
      #       input: ->(section_id, ctx) { { document_id: ctx[:document_id], section_id: } },
      #       into: :section_reviews, collect: :outputs, on_item_failure: :collect
      #   call Documents::Summarize, input: ->(ctx) { { document_id: ctx[:document_id] } },
      #        timeout: 3600, into: :summary
      #   spawn :watcher_ids, workflow: Watchers::Notify, max_items: 1_000,
      #         input: ->(watcher_id, ctx) { { watcher_id: } }
      #
      # `map` launches a run per item and waits, bounded by `timeout:`, for
      # the host to resume the parent with every child's result; `call` is a
      # map of one whose `into:` gets the child's output itself; `spawn`
      # launches and continues. `items` is a context key holding an Array or
      # a callable of the context, and more than `max_items` fails the step
      # before anything launches. `input:` returns each child's whole
      # context.
      module ChildRunDeclarations
        MAX_ITEMS = 10_000
        COLLECT_MODES = %i[outputs states none].freeze
        FAILURE_MODES = %i[fail collect].freeze
        # Each kind's required options, optional ones with their defaults,
        # and the settings it fixes.
        OPTIONS = {
          map: { required: %i[workflow max_items input timeout into],
                 optional: { collect: :outputs, on_item_failure: :fail }, fixed: {} },
          call: { required: %i[input timeout into], optional: {},
                  fixed: { max_items: 1, collect: :outputs, on_item_failure: :fail } },
          spawn: { required: %i[workflow max_items input], optional: {},
                   fixed: { collect: :none, on_item_failure: :collect } }
        }.freeze
        private_constant :OPTIONS

        attr_reader :children_config

        def map(items, **options) = declare_child_runs!(:map, items, options)

        def call(workflow, **options) = declare_child_runs!(:call, nil, options, workflow:)

        def spawn(items, **options) = declare_child_runs!(:spawn, items, options)

        def child_runs? = !@children_config.nil?

        def spawns? = @children_config&.fetch(:kind) == :spawn

        private

        # A map or call that fails when a child fails needs on_failure. No
        # map, call or spawn retries: its launcher retries launching, and a
        # map's results arrive with the host's resume, outside any attempt.
        def validate_child_run_controls!
          return unless child_runs?
          raise WorkflowError, "a map, call or spawn does not take retry_on" if @retry_config
          return unless @children_config.fetch(:on_item_failure) == :fail && @failure_transition.nil?

          raise WorkflowError, "a map or call that fails when a child fails must declare on_failure"
        end

        def declare_child_runs!(kind, items, options, given = {})
          validate_execution_primitive_conflict!(kind.to_s)
          settings = child_run_options!(kind, options).merge(given)
          validate_child_runs!(kind, items, settings)
          @children_config = settings.slice(:workflow, :max_items, :input, :collect, :on_item_failure)
                                     .merge(kind:, items:).freeze
          wait_for_children!(settings[:into], settings[:timeout], kind) unless kind == :spawn
          commit_execution_primitive!(kind.to_s)
        end

        def child_run_options!(kind, options)
          spec = OPTIONS.fetch(kind)
          refuse_options!(kind, "does not take", options.keys - spec[:required] - spec[:optional].keys)
          refuse_options!(kind, "needs", spec[:required] - options.keys)
          spec[:optional].merge(options).merge(spec[:fixed])
        end

        def refuse_options!(kind, problem, names)
          raise WorkflowError, "#{kind} #{problem} #{names.map(&:inspect).join(", ")}" if names.any?
        end

        def validate_child_runs!(kind, items, settings)
          workflow = settings[:workflow]
          unless workflow.is_a?(Class) && workflow < Workflow
            raise WorkflowError, "#{kind} workflow must be a Smith::Workflow subclass"
          end
          raise WorkflowError, "#{kind} input: must be a callable" unless settings[:input].respond_to?(:call)

          validate_child_items!(kind, items, settings[:max_items])
          validate_child_modes!(kind, settings[:collect], settings[:on_item_failure])
        end

        def validate_child_items!(kind, items, max_items)
          unless kind == :call || items.is_a?(Symbol) || items.respond_to?(:call)
            raise WorkflowError, "#{kind} items must be a Symbol context key or a callable of the context"
          end
          return if max_items.is_a?(Integer) && max_items.between?(1, MAX_ITEMS)

          raise WorkflowError, "#{kind} max_items: must be an Integer from 1 to #{MAX_ITEMS}"
        end

        def validate_child_modes!(kind, collect, on_item_failure)
          unless COLLECT_MODES.include?(collect)
            raise WorkflowError, "#{kind} collect: must be one of #{COLLECT_MODES.inspect}"
          end
          return if FAILURE_MODES.include?(on_item_failure)

          raise WorkflowError, "#{kind} on_item_failure: must be one of #{FAILURE_MODES.inspect}"
        end

        # A map or call waits like an await, for the event `children`.
        def wait_for_children!(into, timeout, kind)
          raise WorkflowError, "#{kind} into: must be a Symbol context key" unless into.is_a?(Symbol)

          @await_config = { kind: :children, event: :children, into:,
                            timeout: wait_seconds!(timeout, "#{kind} timeout:"), block: nil }.freeze
        end
      end

      include ChildRunDeclarations
    end
  end
end
