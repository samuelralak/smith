# frozen_string_literal: true

require "open3"

# A bare constant in a host's class body, its methods and its `def self.` is
# looked up through the class's ancestors, and in its `class << self` through
# its singleton class's, each before Object: a constant on Smith::Workflow,
# Agent, Context or Tool, or on a module one of them includes or extends,
# public or private, shadows a host's own top-level constant of that name.
RSpec.describe "The constants a host's Workflow, Agent, Context or Tool subclass sees" do
  let(:classes) { %w[Workflow Agent Context Tool] }

  # 0.16.0's constants a host body saw, public and private, and the homes
  # its fixes gave them.
  let(:moved) do
    %w[ImageRequest PaintInput PaintedAnswer ProviderPaint MODERATION_BLOCKED NestedItemsExecution Envelope Painted
       Unkept MEDIA_TYPES ImageAttempt NestedItems IMAGE_MEDIA_TYPES]
  end

  # What each class and side showed in 0.15.0, but each class's own public
  # constants (its namespace, which the harness holds against the release).
  let(:released) do
    {
      "Workflow instance" => %w[
        AGENT_DIM_MAP ATTEMPT BUDGET_DIMENSIONS BUDGET_KEYS BUILT Boundary BoundaryReset CALLS_LOCK CAPTURED
        COST_DIMENSIONS CanonicalPayloadDigest Captured Checkpoint CheckpointState ClassMethods
        CompositeBranchAuthorization CompositeBranchEffects CompositeBranchExecution CompositeBranchOutcome
        CompositeExecution CompositePreparation CompositeReductionExecution DESCRIPTOR_PHASES DIGEST
        DefinitionBoundary DispatchBoundary DispatchClaim DispatchConfirmation DispatchVerification
        EMPTY_ERROR_CLASSES EXCEPTION_CAUSE EXTENSIONS Execution ExecutionAuthorization
        ExecutionAuthorizationIssuance ExecutionBindingCollector ExecutionBindingSnapshot ExecutionLifecycle
        ExecutionResultCapture ExecutionVerification ExecutionWorkflowSnapshot INHERITED_NAMESPACES
        INHERITED_UNTRUSTED_KEYS INPUT_ROLES Inheritance LIGHTWEIGHT_SCALARS MAX_CACHE_BREAKPOINTS MAX_CALLS
        MAX_INHERITED_NAMESPACES MAX_LAUNCH_BYTES MODEL_PERMISSION_ERRORS MODEL_UNAVAILABLE_STATUSES
        NO_PARALLEL_BINDING NO_SPLIT_TRANSITION PAUSE_MARGIN PENDING_BATCH_FIELDS PENDING_PROGRESS_FIELDS
        PENDING_RETRY_FIELDS PROGRESS_FIELDS PROVIDER_ACCOUNT_ERRORS Payloads Plan Preparation PreparationClaim
        PreparationPayload PreparationRecovery PreparedBranchExecution ProcessLocal RECORD_FIELDS RENAMED_RECORDS
        REPAIR_NOTE REPAIR_TASK RESULT_KEYS RESULT_MARGIN ROLES RaisedChildUsage Recovery RecoveryBoundary
        RecoveryClassMethods ReplaceExactSignature RestartSafeAdapter Resumed SOURCES STATUSES STREAM_RESETS Scope
        Shape StateSnapshot SubclassBoundary TOKEN_DIMENSIONS TRANSIENT_ERRORS ThreadContextSnapshot TimedOutStep
        Timer TransactionIdentity TransitionContract TransitionContractFreezer TransitionContractSignature
        TransitionContractStructuredValues UNTOLD_FIELDS UnsupportedSteps WAIT_PENDING WAIT_SECONDS
        WORKFLOW_CONTINUATION_MESSAGE WaitRecord
      ],
      "Workflow class" => [],
      "Agent instance" => %w[BUDGET_KEYS EXECUTION_IDENTITY_UNSET TOOL_BUDGET_EXHAUSTION_POLICIES
                             TOOL_BUDGET_EXHAUSTION_UNSET],
      "Agent class" => %w[FAIL MAX_REPAIRS MODES UNSET],
      "Context instance" => [],
      "Context class" => [],
      "Tool instance" => %w[CAPTURE_FAILED ExecutionAuthority],
      "Tool class" => %w[CONTEXT_KEYS NOT_INHERITED]
    }
  end

  # Ruby lists only public constants, so private ones are looked for by every
  # name Smith's lib defines or marks private.
  let(:defined_names) do
    named = /^\s*(?:class|module)\s+(?:\w+::)*([A-Z]\w*)/
    assigned = /^\s*([A-Z]\w*)\s*=[^=~>]/
    made_private = /private_constant\s+((?::\w+\s*,?\s*)+)/
    Dir[File.expand_path("../../lib/**/*.rb", __dir__)].flat_map do |file|
      text = File.read(file)
      [*text.scan(named), *text.scan(assigned), *text.scan(made_private).flatten.map { _1.scan(/\w+/) }].flatten
    end.uniq.map(&:to_sym)
  end

  # Every constant a bare name finds through Smith's own ancestors of
  # `owner`, but `klass`'s own public ones.
  def seen(owner, klass)
    smith = owner.ancestors.select { (_1.name || _1.inspect).match?(/\A(#<Class:)?Smith::/) }
    smith.flat_map { |ancestor| held(ancestor, own: ancestor.equal?(klass)) }.map(&:to_s).uniq.sort
  end

  # Public and private, or only private for a class's own.
  def held(ancestor, own:)
    listed = ancestor.constants(false)
    found = (listed + defined_names.select { ancestor.const_defined?(_1, false) }).uniq
    own ? found - listed : found
  end

  it "finds a host's own constant of each name 0.16.0 gave a host body, in a body, method or class << self" do
    script = <<~RUBY
      require "smith"
      names = #{moved.map(&:to_sym).inspect}
      names.each { Object.const_set(_1, :host) }
      found = #{classes.inspect}.product(names).flat_map do |base, name|
        host = eval(<<~HOST, TOPLEVEL_BINDING)
          class Host\#{base}\#{name} < Smith::\#{base}
            BODY = \#{name}
            def own = \#{name}
            def self.own = \#{name}
            class << self
              def meta = \#{name}
            end
          end
          Host\#{base}\#{name}
        HOST
        { body: host::BODY, method: host.allocate.own, def_self: host.own, class_self: host.meta }
          .reject { |_where, value| value == :host }.map { |where, value| "\#{base} \#{where} \#{name}: \#{value.inspect}" }
      end
      p found
    RUBY
    stdout, stderr, status = Open3.capture3(RbConfig.ruby, "-I", File.expand_path("../../lib", __dir__), "-e", script)

    expect([status.success?, stderr]).to eq([true, ""])
    expect(stdout).to eq("[]\n")
  end

  it "holds no constant a host body can see, public or private, on either side, but those 0.15.0's held" do
    seen_now = classes.flat_map do |name|
      klass = Smith.const_get(name)
      [["#{name} instance", seen(klass, klass)], ["#{name} class", seen(klass.singleton_class, klass)]]
    end.to_h

    expect(seen_now).to eq(released)
  end
end
