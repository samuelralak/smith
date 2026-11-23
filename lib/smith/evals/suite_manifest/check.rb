# frozen_string_literal: true

module Smith
  module Evals
    module SuiteManifest
      # Internal. Facts about declared values, shared by the checks. Text
      # is UTF-8 (or ASCII) before a pattern reads it, and an Integer at
      # most 2**53 - 1, so whatever passes has a canonical JSON form.
      module Facts
        MAX_INTEGER = CanonicalJSON::MAX_SAFE_INTEGER
        # A Ruby class's name as a constant path, as the manifest writes it.
        CLASS_NAME = /\A[A-Z][A-Za-z0-9_]*(?:::[A-Z][A-Za-z0-9_]*)*\z/
        # The classes design 6.3 counts as the subject's own failures (output,
        # refusals, limits and budget, tools, guardrails, agents, steps): an
        # infrastructure error that is one of them or an ancestor would take
        # them out of the rate, leaving only the successes. ScriptError is
        # as broad (NotImplementedError, LoadError).
        SUBJECT_FAILURES = %w[OutputFailure OutputInvalid OutputRefused OutputTruncated BlankAgentOutputError
                              ProviderPermanentFailure BudgetExceeded BudgetUnavailable DeadlineExceeded
                              MaxTransitionsExceeded GuardrailFailed ToolGuardrailFailed ToolPolicyDenied
                              ToolDispatchRejected ToolCaptureFailed ToolOutcomeUncertain ToolExecutionNotAdmitted
                              ToolFailureNotificationFailed BoundedCompletionError DeterministicStepFailure
                              WorkflowError WaitTimedOut ChildRunsFailed ContentUnavailable PersistedStateTooLarge
                              BatchRequestInvalid UnresolvedTransitionError].freeze

        module_function

        def integer?(value, low, high = MAX_INTEGER) = value.is_a?(Integer) && value.between?(low, high)
        def real?(value) = value.is_a?(Numeric) && value.real? && value.to_f.finite?
        def text?(value) = (value.is_a?(String) || value.is_a?(Symbol)) && JSONValue.utf8?(value.to_s)
        def name?(value, limit) = text?(value) && value.to_s.length.between?(1, limit)
        def matches?(value, pattern) = text?(value) && pattern.match?(value.to_s)
        def folder?(value) = (value.is_a?(String) || value.respond_to?(:to_path)) && !value.to_s.empty?
        def digest?(value) = value.is_a?(String) && value.ascii_only? && Identity::CONTENT_HASH.match?(value)
        def host_source?(source) = source.respond_to?(:manifest) && source.respond_to?(:each_sample)

        def error_class?(item)
          item.is_a?(Class) && item <= Exception && matches?(item.name, CLASS_NAME) && item.name.length <= 256
        end

        # Whether an error class would count the subject's own failures as
        # infrastructure: ScriptError, or a subject failure class or one of
        # its ancestors (Exception, StandardError and Smith::Error among them).
        def too_broad?(item)
          item <= ScriptError || SUBJECT_FAILURES.any? { Smith.const_get(_1) <= item }
        end

        # The name a scorer declaration gives, whether or not it is refused.
        def scorer_name_of(entry)
          target = entry[:target]
          return target.name if target.is_a?(Scorer)
          return target.scorer_name&.to_s if target.is_a?(Class) && target < Scorer

          target.to_s if entry[:block]
        end

        # A non-empty list, each item fitting, distinct as the manifest
        # writes them (Symbols as their names).
        def distinct?(list, &)
          list.is_a?(Array) && !list.empty? && list.all?(&) && list.map(&:to_s).uniq.size == list.size
        end
      end
      private_constant :Facts

      # Internal. A code suite's declarations, checked section by section in
      # manifest order: every problem as "path: problem", a JSON Pointer
      # into the manifest or the DSL name of a setting it leaves out.
      class Check
        include Facts

        MAX_SOURCE_CHARACTERS = 512
        MAX_INFRASTRUCTURE_ERRORS = 64

        attr_reader :problems, :scorers, :gates

        def initialize(suite)
          @suite = suite
          @settings = suite.settings
          @problems = []
          check_header
          check_selection
          check_subject
          check_trials
          @scorers = ScorerCheck.new(@settings[:scorers], default_reduce: reduce, per_sample:, problems: @problems)
          SettingsCheck.new(@settings, @problems)
          @gates = GateCheck.new(@settings[:gates], @scorers, @problems)
          @problems.freeze
        end

        def reduce = SuiteManifest.reducer_name(@settings[:reduce])

        private

        # Records the problem unless the fact holds.
        def need(fact, line) = (@problems << line unless fact)

        def per_sample = @settings[:trials]

        def check_header
          need(matches?(@suite.suite_name, Identity::NAME),
               "/name: is a name (^[a-z][a-z0-9_.-]{0,127}$); an anonymous suite needs suite_name")
          source = @settings[:dataset]
          need(!source.nil?, '/dataset: is required: dataset "folder" or a source')
          need(source.nil? || folder?(source) || host_source?(source),
               "/dataset: is a folder or a source answering manifest(scope:) and each_sample(scope:)")
          check_dataset(source)
        end

        def check_dataset(source)
          need(!folder?(source) || name?(@suite.dataset_source.to_s, MAX_SOURCE_CHARACTERS),
               "/dataset/source: is a path of at most #{MAX_SOURCE_CHARACTERS} characters of UTF-8")
          pin = @settings[:pinned_version]
          need(pin.nil? || digest?(pin), "/dataset/pinned_version: is a digest: sha256: and 64 lowercase hex digits")
        end

        def check_selection
          split = @settings[:split].to_s
          need(SPLITS.include?(split), "/selection/split: is dev, holdout or calibration, not #{split}")
          narrow = @settings[:narrow]
          return if narrow.nil?
          return need(false, "/selection/narrow: is ids: or tags_any:, not both or neither") unless narrow.size == 1

          check_narrowing(*narrow.first)
        end

        # Narrowing ids are sample ids; tags are names.
        def check_narrowing(key, list)
          ids = key == :ids
          fits = distinct?(list) { ids ? matches?(_1, Identity::SAMPLE_ID) : name?(_1, 256) }
          need(fits, "/selection/narrow/#{key}: is a list of distinct #{ids ? "sample ids" : "names"}")
        end

        def check_subject
          subject = @settings[:subject]
          return need(false, "/subject: is required: subject workflow:, input:") if subject.nil?
          return need(false, "/subject: is a Smith::Evals::Subject") unless subject.is_a?(Subject)

          @problems.concat(subject.problems)
        end

        def check_trials
          need(integer?(per_sample, 1, 100), "/trials/per_sample: is an Integer from 1 to 100, not #{per_sample}")
          retries = @settings[:error_retries]
          need(integer?(retries, 0, 10), "/trials/error_retries: is an Integer from 0 to 10, not #{retries}")
          check_infrastructure_errors(@settings[:infrastructure_errors])
          concurrency = @settings[:concurrency]
          need(integer?(concurrency, 1), "concurrency: is an Integer of at least 1, not #{concurrency}")
          check_reduce
        end

        # Written as sorted class names: they decide which failures count
        # against the rate (design 6.3), so they are part of the measure.
        def check_infrastructure_errors(classes)
          path = "/trials/infrastructure_errors"
          need(classes.size <= MAX_INFRASTRUCTURE_ERRORS, "#{path}: names at most #{MAX_INFRASTRUCTURE_ERRORS} classes")
          classes.each_with_index do |item, index|
            next need(false, "#{path}/#{index}: is a named Exception class") unless error_class?(item)

            need(!too_broad?(item), "#{path}/#{index}: #{item.name} is too broad: it would count the subject's own " \
                                    "failures as infrastructure")
          end
          need(classes.uniq.size == classes.size, "#{path}: names a class twice")
        end

        def check_reduce
          return need(false, "/trials/reduce: is majority, any, all, mean, pass_at_<k> or pass_all_<k>") if reduce.nil?

          k = Reducers.k(reduce)
          need(k.nil? || !integer?(per_sample, 1, 100) || k <= per_sample,
               "/trials/reduce: #{reduce} needs at least #{k} trials per sample")
        end
      end
      private_constant :Check

      # Internal. A suite's statistics, budget, label rule and recording,
      # checked into the problem list it is given.
      class SettingsCheck
        include Facts

        MAX_CONFIDENCE = 0.999999999
        LABELS = %w[any human_only].freeze
        STATISTICS = %i[level bootstrap_resamples small_sample_threshold].freeze

        def initialize(settings, problems)
          @settings = settings
          @problems = problems
          check_statistics(settings[:statistics])
          check_settings
          check_recording(settings[:recording])
        end

        private

        def need(fact, line) = (@problems << line unless fact)

        def check_statistics(settings)
          (settings.keys - STATISTICS).each { need(false, "/statistics: unknown setting #{_1}") }
          level = settings[:level]
          need(real?(level) && level.positive? && level <= MAX_CONFIDENCE,
               "/statistics/level: is a number above 0 and at most #{MAX_CONFIDENCE}")
          need(integer?(settings[:bootstrap_resamples], 100, 100_000),
               "/statistics/bootstrap_resamples: is an Integer from 100 to 100000")
          need(integer?(settings[:small_sample_threshold], 1),
               "/statistics/small_sample_threshold: is an Integer from 1 to 2**53 - 1")
        end

        def check_settings
          budget = @settings[:budget]
          need(budget.nil? || integer?(budget[:max_cost_nanos], 0),
               "/budget/max_cost_nanos: is an Integer from 0 to 2**53 - 1")
          need(LABELS.include?(@settings.dig(:labels, :accept).to_s), "/labels/accept: is any or human_only")
        end

        def check_recording(recording)
          need([true, false].include?(recording[:content]), "/recording/content: is true or false")
          (recording.keys - [:content]).each { need(false, "/recording: unknown setting #{_1}") }
        end
      end
      private_constant :SettingsCheck
    end
  end
end
