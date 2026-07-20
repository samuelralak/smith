# frozen_string_literal: true

require "timeout"

RSpec.describe "Smith::Workflow parallel execution" do
  let(:agent_class) { require_const("Smith::Agent") }
  let(:context_class) { require_const("Smith::Context") }
  let(:guardrails_class) { require_const("Smith::Guardrails") }
  let(:tool_class) { require_const("Smith::Tool") }
  let(:workflow_class) { require_const("Smith::Workflow") }
  let(:workflow_error) { require_const("Smith::WorkflowError") }
  let!(:parallel_agent) do
    with_stubbed_class("SpecParallelAgent", agent_class) do
      register_as :spec_parallel_agent
    end
  end
  let!(:nested_fanout_agent) do
    with_stubbed_class("SpecParallelNestedFanoutAgent", agent_class) do
      register_as :spec_parallel_nested_fanout_agent
    end
  end

  it "returns one branch result per configured branch when a parallel transition succeeds" do
    workflow = with_stubbed_class("SpecParallelWorkflow", workflow_class) do
      initial_state :idle
      state :done

      transition :fan_out, from: :idle, to: :done do
        execute :spec_parallel_agent, parallel: true, count: 3
      end
    end.new

    result = workflow.run!

    expect(result.state).to eq(:done)
    expect(result.steps.length).to eq(1)
    expect(result.output).to eq(
      [
        { branch: 0, agent: :spec_parallel_agent, output: nil },
        { branch: 1, agent: :spec_parallel_agent, output: nil },
        { branch: 2, agent: :spec_parallel_agent, output: nil }
      ]
    )
  end

  it "uses a callable branch count with the workflow context" do
    workflow = with_stubbed_class("SpecParallelCallableCountWorkflow", workflow_class) do
      initial_state :idle
      state :done

      transition :fan_out, from: :idle, to: :done do
        execute :spec_parallel_agent, parallel: true, count: ->(context) { context.fetch(:branch_count) }
      end
    end.new(context: { branch_count: 2 })

    result = workflow.run!

    expect(result.state).to eq(:done)
    expect(result.output.length).to eq(2)
    expect(result.output.map { |branch| branch[:branch] }).to eq([0, 1])
  end

  it "does not leak an outer parallel binding into a re-entrant workflow" do
    outer_agent = Class.new(Smith::Agent) do
      register_as :spec_outer_parallel_agent
      model "outer-model"
    end
    inner_agent = Class.new(Smith::Agent) do
      register_as :spec_inner_parallel_agent
      model "inner-model"
    end
    inner_bindings = []
    inner_workflow = Class.new(Smith::Workflow) do
      initial_state :idle
      state :done
      transition :finish, from: :idle, to: :done do
        execute :spec_inner_parallel_agent, parallel: true, count: 1
      end

      define_method(:invoke_agent) do |agent_class, _prepared_input|
        inner_bindings << agent_class
        "inner"
      end
      private :invoke_agent
    end
    outer_workflow = Class.new(Smith::Workflow) do
      initial_state :idle
      state :done
      transition :finish, from: :idle, to: :done do
        execute :spec_outer_parallel_agent, parallel: true, count: 1
      end
    end.new
    outer_workflow.define_singleton_method(:execute_transition_body) do |_transition, prepared_input: nil|
      inner_workflow.new.run!
      prepared_input
    end

    expect(outer_workflow.run!).to be_done
    expect(inner_bindings).to eq([inner_agent])
    expect(inner_bindings).not_to include(outer_agent)
  end

  it "restores outer execution context after nested branch work" do
    original = Smith::Workflow.const_get(:ThreadContextSnapshot, false).new
    outer = {
      guardrails: Object.new,
      deadline: Time.now.utc + 60,
      ledger: Object.new,
      allowance: { remaining: 4 },
      collector: proc {},
      invocation_context: Object.new,
      artifacts: Object.new
    }
    Smith::Tool.current_guardrails = outer[:guardrails]
    Smith::Tool.current_deadline = outer[:deadline]
    Smith::Tool.current_ledger = outer[:ledger]
    Smith::Tool.current_tool_call_allowance = outer[:allowance]
    Smith::Tool.current_tool_result_collector = outer[:collector]
    Smith::Tool.current_invocation_context = outer[:invocation_context]
    Smith.scoped_artifacts = outer[:artifacts]
    env = Smith::Workflow::BranchEnv.new(deadline: Time.now.utc + 10)
    workflow = Class.new(workflow_class) do
      initial_state :idle
    end.new

    workflow.send(:with_branch_context, env, Object.new) { nil }

    expect(Smith::Tool.current_guardrails).to equal(outer[:guardrails])
    expect(Smith::Tool.current_deadline).to equal(outer[:deadline])
    expect(Smith::Tool.current_ledger).to equal(outer[:ledger])
    expect(Smith::Tool.current_tool_call_allowance).to equal(outer[:allowance])
    expect(Smith::Tool.current_tool_result_collector).to equal(outer[:collector])
    expect(Smith::Tool.current_invocation_context).to equal(outer[:invocation_context])
    expect(Smith.scoped_artifacts).to equal(outer[:artifacts])
  ensure
    original&.restore!
  end

  it "preserves the public BranchEnv value-object interface" do
    deadline = Time.now.utc + 10
    env = Smith::Workflow::BranchEnv.new(prepared_input: "input", deadline:)

    expect(env.members).to eq(
      %i[prepared_input guardrail_sources scoped_store branch_estimates deadline agent_class]
    )
    expect(env.to_h).to include(prepared_input: "input", deadline:)
    expect(env).to eq(Smith::Workflow::BranchEnv.new(prepared_input: "input", deadline:))
    expect { env.deadline = nil }.to change(env, :deadline).from(deadline).to(nil)
  end

  it "preserves the public BranchEnv thread lifecycle behavior" do
    guardrails = Object.new
    deadline = Time.now.utc + 10
    artifacts = Object.new
    env = Smith::Workflow::BranchEnv.new(
      guardrail_sources: guardrails,
      deadline:,
      scoped_store: artifacts
    )

    expect(env.setup_thread).to equal(artifacts)
    expect(Smith::Tool.current_guardrails).to equal(guardrails)
    expect(Smith::Tool.current_deadline).to equal(deadline)
    expect(Smith.scoped_artifacts).to equal(artifacts)
    expect(env.teardown_thread).to be_nil
    expect(Smith::Tool.current_guardrails).to be_nil
    expect(Smith::Tool.current_deadline).to be_nil
    expect(Smith.scoped_artifacts).to be_nil
  end

  it "preserves ordinary workflow branch extension points" do
    calls = Queue.new
    base = Class.new(workflow_class) do
      initial_state :idle
      state :done
      transition :finish, from: :idle, to: :done do
        execute :spec_parallel_agent, parallel: true, count: 2
      end
    end
    workflow = Class.new(base) do
      define_method(:run_branch) do |*arguments|
        calls << :called
        super(*arguments)
      end
      private :run_branch
    end.new

    expect(workflow.run!).to be_done
    expect(calls.size).to eq(2)
  end

  it "propagates opaque invocation context to every same-agent parallel branch" do
    invocation_context = Object.new
    observed = Queue.new
    workflow = with_stubbed_class("SpecParallelInvocationContextWorkflow", workflow_class) do
      initial_state :idle
      state :done

      transition :fan_out, from: :idle, to: :done do
        execute :spec_parallel_agent, parallel: true, count: 3
      end
    end.new
    workflow.define_singleton_method(:execute_transition_body) do |_transition, prepared_input: nil|
      observed << Smith::Tool.current_invocation_context
      prepared_input
    end

    Smith::Tool.with_invocation_context(invocation_context) { workflow.run! }

    expect(3.times.map { observed.pop }).to all(equal(invocation_context))
    expect(Smith::Tool.current_invocation_context).to be_nil
  end

  it "restores complete branch context across nested parallel and fan-out workflows" do
    capture = lambda do
      {
        guardrails: Smith::Tool.current_guardrails,
        deadline: Smith::Tool.current_deadline,
        ledger: Smith::Tool.current_ledger,
        allowance: Smith::Tool.current_tool_call_allowance,
        collector: Smith::Tool.current_tool_result_collector,
        invocation_context: Smith::Tool.current_invocation_context,
        artifacts: Smith.scoped_artifacts,
        call_deadline: Thread.current[:smith_call_deadline],
        call_ledger: Thread.current[:smith_call_ledger],
        failed_results: Thread.current[:smith_failed_agent_results],
        last_result: Thread.current[:smith_last_agent_result],
        parallel_binding: Thread.current[:smith_parallel_agent_binding]
      }
    end
    inner_parallel = Class.new(workflow_class) do
      initial_state :idle
      state :done
      transition :finish, from: :idle, to: :done do
        execute :spec_parallel_agent, parallel: true, count: 1
      end
    end
    inner_fanout = Class.new(workflow_class) do
      initial_state :idle
      state :done
      transition :finish, from: :idle, to: :done do
        fan_out branches: {
          first: :spec_parallel_agent,
          second: :spec_parallel_nested_fanout_agent
        }
      end
    end

    [inner_parallel, inner_fanout].each do |inner|
      observations = Queue.new
      outer = Class.new(workflow_class) do
        initial_state :idle
        state :done
        transition :finish, from: :idle, to: :done do
          execute :spec_parallel_agent, parallel: true, count: 2
        end
      end.new
      outer.define_singleton_method(:execute_transition_body) do |_transition, prepared_input: nil|
        before = capture.call
        inner.new.run!
        observations << [before, capture.call]
        prepared_input
      end

      expect(outer.run!).to be_done
      2.times do
        before, after = observations.pop
        expect(after).to eq(before)
      end
    end
  end

  it "restores worker context after branch failure and cooperative cancellation" do
    capture = lambda do
      [
        Smith::Tool.current_guardrails,
        Smith::Tool.current_deadline,
        Smith::Tool.current_ledger,
        Smith::Tool.current_tool_call_allowance,
        Smith::Tool.current_tool_result_collector,
        Smith::Tool.current_invocation_context,
        Smith.scoped_artifacts,
        Thread.current[:smith_call_deadline],
        Thread.current[:smith_call_ledger],
        Thread.current[:smith_failed_agent_results],
        Thread.current[:smith_last_agent_result],
        Thread.current[:smith_parallel_agent_binding]
      ]
    end
    install = lambda do
      Smith::Tool.current_guardrails = Object.new
      Smith::Tool.current_deadline = Time.now.utc + 60
      Smith::Tool.current_ledger = Object.new
      Smith::Tool.current_tool_call_allowance = { remaining: 7 }
      Smith::Tool.current_tool_result_collector = proc {}
      Smith::Tool.current_invocation_context = Object.new
      Smith.scoped_artifacts = Object.new
      Thread.current[:smith_call_deadline] = Time.now.utc + 30
      Thread.current[:smith_call_ledger] = Object.new
      Thread.current[:smith_failed_agent_results] = [Object.new]
      Thread.current[:smith_last_agent_result] = Object.new
      Thread.current[:smith_parallel_agent_binding] = Object.new
    end
    observations = Queue.new
    attempts = 0
    mutex = Mutex.new
    started = Concurrent::CountDownLatch.new(2)
    base = Class.new(workflow_class) do
      initial_state :idle
      state :done
      state :failed
      transition :finish, from: :idle, to: :done do
        execute :spec_parallel_agent, parallel: true, count: 2
        on_failure :fail
      end
    end
    workflow = Class.new(base) do
      define_method(:run_branch) do |*arguments|
        install.call
        before = capture.call
        super(*arguments)
      ensure
        observations << [before, capture.call]
      end
    end.new
    workflow.define_singleton_method(:guarded_branch_call) do |_transition, _env, signal|
      attempt = mutex.synchronize { attempts += 1 }
      started.count_down
      started.wait(1)
      raise Smith::AgentError, "initiating failure" if attempt == 1

      sleep 0.05
      check_cancellation!(signal)
    end

    expect(workflow.run!.state).to eq(:failed)
    2.times do
      before, after = observations.pop
      expect(after).to eq(before)
    end
  end

  it "rejects non-positive parallel branch counts before executing branches" do
    expect do
      with_stubbed_class("SpecParallelZeroCountWorkflow", workflow_class) do
        initial_state :idle
        state :done

        transition :fan_out, from: :idle, to: :done do
          execute :spec_parallel_agent, parallel: true, count: 0
        end
      end
    end.to raise_error(workflow_error, /parallel branch count must be a positive integer/)
  end

  it "rejects callable parallel branch counts that do not resolve to positive integers" do
    workflow = with_stubbed_class("SpecParallelBadCallableCountWorkflow", workflow_class) do
      initial_state :idle
      state :done

      transition :fan_out, from: :idle, to: :done do
        execute :spec_parallel_agent, parallel: true, count: ->(_context) { "two" }
      end
    end.new

    expect { workflow.run! }
      .to raise_error(workflow_error, /parallel branch count must be a positive integer/)
  end

  it "rejects oversized dynamic branch counts before branch allocation" do
    original_limit = Smith.config.parallel_branch_limit
    Smith.config.parallel_branch_limit = 4
    workflow = with_stubbed_class("SpecParallelOversizedCountWorkflow", workflow_class) do
      initial_state :idle
      state :done

      transition :fan_out, from: :idle, to: :done do
        execute :spec_parallel_agent, parallel: true, count: ->(_context) { 1_000_000 }
      end
    end.new

    expect { workflow.run! }.to raise_error(workflow_error, /exceeds configured limit 4/)
  ensure
    Smith.config.parallel_branch_limit = original_limit
  end

  it "rejects oversized static branch counts at declaration time" do
    original_limit = Smith.config.parallel_branch_limit
    Smith.config.parallel_branch_limit = 4

    expect do
      Class.new(workflow_class) do
        initial_state :idle
        state :done
        transition :fan_out, from: :idle, to: :done do
          execute :spec_parallel_agent, parallel: true, count: 1_000_000
        end
      end
    end.to raise_error(workflow_error, /exceeds configured limit 4/)
  ensure
    Smith.config.parallel_branch_limit = original_limit
  end

  it "revalidates static branch counts before resolving runtime bindings" do
    original_limit = Smith.config.parallel_branch_limit
    Smith.config.parallel_branch_limit = 3
    workflow = Class.new(workflow_class) do
      initial_state :idle
      state :done
      transition :fan_out, from: :idle, to: :done do
        execute :missing_parallel_agent, parallel: true, count: 3
      end
    end.new

    Smith.config.parallel_branch_limit = 2

    expect { workflow.run! }.to raise_error(workflow_error, /exceeds configured limit 2/)
  ensure
    Smith.config.parallel_branch_limit = original_limit
  end

  it "bounds active branches and preserves declaration order" do
    original_concurrency = Smith.config.parallel_concurrency
    Smith.config.parallel_concurrency = 3
    mutex = Mutex.new
    active = 0
    maximum_active = 0
    branches = Array.new(24) do |index|
      proc do
        mutex.synchronize do
          active += 1
          maximum_active = [maximum_active, active].max
        end
        sleep 0.005
        index
      ensure
        mutex.synchronize { active -= 1 }
      end
    end

    expect(Smith::Workflow::Parallel.execute(branches:)).to eq((0...24).to_a)
    expect(maximum_active).to eq(3)
  ensure
    Smith.config.parallel_concurrency = original_concurrency
  end

  it "does not start queued branch callables after cancellation" do
    original_concurrency = Smith.config.parallel_concurrency
    Smith.config.parallel_concurrency = 1
    started = Queue.new
    branches = Array.new(25) do |index|
      proc do
        started << index
        raise Smith::WorkflowError, "initiating failure" if index.zero?

        index
      end
    end

    expect { Smith::Workflow::Parallel.execute(branches:) }
      .to raise_error(workflow_error, "initiating failure")
    expect(started.size).to eq(1)
  ensure
    Smith.config.parallel_concurrency = original_concurrency
  end

  it "surfaces the branch error that initiated cancellation" do
    original_concurrency = Smith.config.parallel_concurrency
    Smith.config.parallel_concurrency = 2
    started = Concurrent::CountDownLatch.new(2)
    branches = [
      proc do
        started.count_down
        started.wait(1)
        sleep 0.02
        raise Smith::WorkflowError, "secondary failure"
      end,
      proc do
        started.count_down
        started.wait(1)
        raise Smith::AgentError, "initiating failure"
      end
    ]

    expect { Smith::Workflow::Parallel.execute(branches:) }
      .to raise_error(Smith::AgentError, "initiating failure")
  ensure
    Smith.config.parallel_concurrency = original_concurrency
  end

  it "does not detach in-flight branches when external interruption unwinds execution" do
    original_concurrency = Smith.config.parallel_concurrency
    Smith.config.parallel_concurrency = 1
    started = Queue.new
    completed = Queue.new
    branches = Array.new(5) do
      proc do
        started << true
        sleep 0.05
        completed << true
      end
    end
    started_at = Process.clock_gettime(Process::CLOCK_MONOTONIC)

    expect do
      Timeout.timeout(0.02) do
        Smith::Workflow::Parallel.execute(branches:)
      end
    end.to raise_error(Timeout::Error)
    elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started_at

    expect(elapsed).to be >= 0.04
    expect(started.size).to be <= 1
    expect(completed.size).to eq(started.size)
  ensure
    Smith.config.parallel_concurrency = original_concurrency
  end

  it "records accepted nested helpers before an interrupt can unwind submission" do
    executor = Concurrent::FixedThreadPool.new(2)
    submission_accepted = Queue.new
    release_submission = Queue.new
    branch_started = Queue.new
    release_branch = Queue.new
    branch_completed = Queue.new
    original_post = executor.method(:post)
    post_count = 0
    mutex = Mutex.new
    executor.define_singleton_method(:post) do |*args, &task|
      accepted = original_post.call(*args, &task)
      if mutex.synchronize { post_count += 1 } == 1
        submission_accepted << true
        release_submission.pop
      end
      accepted
    end
    context = Smith::Workflow::Parallel::ExecutionContext.new(
      executor:,
      signal: Smith::Workflow::Parallel::CancellationSignal.new,
      concurrency: 3,
      nesting_limit: 4,
      top_level_branch_count: 1
    )
    branches = Array.new(2) do
      proc do
        branch_started << true
        release_branch.pop
        branch_completed << true
      end
    end
    caller = Thread.new do
      context.within(depth: 0) do
        Smith::Workflow::Parallel::NestedExecution.new(branches:, context:).call
      end
    rescue Interrupt => e
      e
    end

    Timeout.timeout(1) { submission_accepted.pop }
    Timeout.timeout(1) { branch_started.pop }
    caller.raise(Interrupt, "interrupt after helper acceptance")
    release_submission << true
    expect(caller.join(0.05)).to be_nil
    2.times { release_branch << true }
    Timeout.timeout(1) { caller.join }

    expect(caller.value).to be_a(Interrupt)
    expect(branch_completed.size).to eq(1)
  ensure
    executor&.shutdown
    executor&.wait_for_termination(1)
  end

  it "does not let a second interrupt detach root workers during cleanup" do
    cleanup_started = Queue.new
    branch_started = Queue.new
    release_branch = Queue.new
    branch_completed = Queue.new
    allow(Concurrent::FixedThreadPool).to receive(:new).and_wrap_original do |constructor, *args, **kwargs|
      executor = constructor.call(*args, **kwargs)
      original_wait = executor.method(:wait_for_termination)
      executor.define_singleton_method(:wait_for_termination) do |timeout = nil|
        cleanup_started << true
        original_wait.call(timeout)
      end
      executor
    end
    caller = Thread.new do
      Smith::Workflow::Parallel.execute(
        branches: [proc do
          branch_started << true
          release_branch.pop
          branch_completed << true
        end]
      )
    rescue Interrupt => e
      e
    end

    Timeout.timeout(1) { branch_started.pop }
    caller.raise(Interrupt, "first interrupt")
    Timeout.timeout(1) { cleanup_started.pop }
    caller.raise(Interrupt, "second interrupt during cleanup")
    expect(caller.join(0.05)).to be_nil
    release_branch << true
    Timeout.timeout(1) { caller.join }

    expect(caller.value).to be_a(Interrupt)
    expect(branch_completed.size).to eq(1)
  end

  it "keeps nested parallel execution within the active worker scope" do
    original_concurrency = Smith.config.parallel_concurrency
    Smith.config.parallel_concurrency = 2
    worker_threads = Queue.new
    inner = Array.new(5) do |index|
      proc do
        worker_threads << Thread.current.object_id
        index
      end
    end
    outer = Array.new(2) do
      proc { Smith::Workflow::Parallel.execute(branches: inner) }
    end

    expect(Smith::Workflow::Parallel.execute(branches: outer)).to eq([0.upto(4).to_a, 0.upto(4).to_a])
    observed = []
    observed << worker_threads.pop until worker_threads.empty?
    expect(observed.uniq.length).to be <= 2
  ensure
    Smith.config.parallel_concurrency = original_concurrency
  end

  it "bounds nested parallel execution before Ruby stack exhaustion" do
    original_limit = Smith.config.parallel_nesting_limit
    Smith.config.parallel_nesting_limit = 3
    recurse = nil
    recurse = lambda do |remaining|
      next :done if remaining.zero?

      Smith::Workflow::Parallel.execute(branches: [proc { recurse.call(remaining - 1) }]).sole
    end

    expect(Smith::Workflow::Parallel.execute(branches: [proc { recurse.call(3) }])).to eq([:done])
    expect { Smith::Workflow::Parallel.execute(branches: [proc { recurse.call(4) }]) }
      .to raise_error(workflow_error, /parallel nesting exceeds configured limit 3/)
  ensure
    Smith.config.parallel_nesting_limit = original_limit
  end

  it "snapshots parallel configuration once for the root execution" do
    allow(Smith.config).to receive(:parallel_concurrency).and_return(2)
    allow(Smith.config).to receive(:parallel_nesting_limit).and_return(4)
    inner = [proc { :inner }]
    outer = [proc { Smith::Workflow::Parallel.execute(branches: inner) }]

    expect(Smith::Workflow::Parallel.execute(branches: outer)).to eq([[:inner]])
    expect(Smith.config).to have_received(:parallel_concurrency).once
    expect(Smith.config).to have_received(:parallel_nesting_limit).once
  end

  it "uses idle top-level workers for nested fan-out without exceeding the shared bound" do
    original_concurrency = Smith.config.parallel_concurrency
    Smith.config.parallel_concurrency = 4
    mutex = Mutex.new
    active = 0
    maximum_active = 0
    inner = Array.new(12) do |index|
      proc do
        mutex.synchronize do
          active += 1
          maximum_active = [maximum_active, active].max
        end
        sleep 0.005
        index
      ensure
        mutex.synchronize { active -= 1 }
      end
    end
    outer = [proc { Smith::Workflow::Parallel.execute(branches: inner) }]

    expect(Smith::Workflow::Parallel.execute(branches: outer)).to eq([0.upto(11).to_a])
    expect(maximum_active).to eq(4)
  ensure
    Smith.config.parallel_concurrency = original_concurrency
  end

  it "propagates outer sibling cancellation into nested fan-out" do
    original_concurrency = Smith.config.parallel_concurrency
    Smith.config.parallel_concurrency = 2
    nested_started = Concurrent::CountDownLatch.new(1)
    inner_starts = Queue.new
    inner = Array.new(30) do
      proc do
        inner_starts << true
        nested_started.count_down
        sleep 0.01
      end
    end
    outer = [
      proc { Smith::Workflow::Parallel.execute(branches: inner) },
      proc do
        nested_started.wait(1)
        raise Smith::AgentError, "outer sibling failed"
      end
    ]

    expect { Smith::Workflow::Parallel.execute(branches: outer) }
      .to raise_error(Smith::AgentError, "outer sibling failed")
    expect(inner_starts.size).to be <= 1
  ensure
    Smith.config.parallel_concurrency = original_concurrency
  end

  it "keeps fiber-nested parallel execution within the active worker scope" do
    original_concurrency = Smith.config.parallel_concurrency
    Smith.config.parallel_concurrency = 2
    worker_threads = Queue.new
    inner = Array.new(5) do |index|
      proc do
        worker_threads << Thread.current.object_id
        index
      end
    end
    outer = Array.new(2) do
      proc { Fiber.new { Smith::Workflow::Parallel.execute(branches: inner) }.resume }
    end

    expect(Smith::Workflow::Parallel.execute(branches: outer)).to eq([0.upto(4).to_a, 0.upto(4).to_a])
    observed = []
    observed << worker_threads.pop until worker_threads.empty?
    expect(observed.uniq.length).to be <= 2
  ensure
    Smith.config.parallel_concurrency = original_concurrency
  end

  it "inherits execution context into child Fibers without leaking into sibling Fibers" do
    executor = Concurrent::FixedThreadPool.new(1)
    context = Smith::Workflow::Parallel::ExecutionContext.new(
      executor:,
      signal: Smith::Workflow::Parallel::CancellationSignal.new,
      concurrency: 1,
      nesting_limit: 4,
      top_level_branch_count: 1
    )
    child_context = nil
    owner = Fiber.new do
      context.within(depth: 2) do
        child_context = Fiber.new do
          [Smith::Workflow::Parallel::ExecutionContext.current,
           Smith::Workflow::Parallel::ExecutionContext.current_depth]
        end.resume
        Fiber.yield
      end
    end

    owner.resume
    sibling_context = Fiber.new do
      [Smith::Workflow::Parallel::ExecutionContext.current,
       Smith::Workflow::Parallel::ExecutionContext.current_depth]
    end.resume
    owner.resume

    expect(child_context).to eq([context, 2])
    expect(sibling_context).to eq([nil, 0])
  ensure
    executor&.shutdown
    executor&.wait_for_termination(1)
  end

  it "reclaims capacity when a top-level branch finishes before its sibling starts" do
    first_completed = Queue.new
    post_count = 0
    post_mutex = Mutex.new
    allow(Concurrent::FixedThreadPool).to receive(:new).and_wrap_original do |constructor, *args, **kwargs|
      executor = constructor.call(*args, **kwargs)
      original_post = executor.method(:post)
      executor.define_singleton_method(:post) do |*post_args, &task|
        count = post_mutex.synchronize { post_count += 1 }
        first_completed.pop if count == 2
        original_post.call(*post_args, &task)
      end
      executor
    end
    inner_started = Concurrent::CountDownLatch.new(2)
    branches = [
      proc do
        first_completed << true
        true
      end,
      proc do
        inner = Array.new(2) do
          proc do
            inner_started.count_down
            raise Smith::WorkflowError, "idle worker capacity was lost" unless inner_started.wait(1)

            :inner
          end
        end
        Smith::Workflow::Parallel.execute(branches: inner)
      end
    ]

    expect(Smith::Workflow::Parallel.execute(branches:)).to eq([true, %i[inner inner]])
  end

  it "applies the same branch bound to heterogeneous fan-out declarations" do
    original_limit = Smith.config.parallel_branch_limit
    Smith.config.parallel_branch_limit = 2

    expect do
      Class.new(workflow_class) do
        initial_state :idle
        state :done
        transition :fan_out, from: :idle, to: :done do
          fan_out branches: { one: :one, two: :two, three: :three }
        end
      end
    end.to raise_error(workflow_error, /fan_out branch count exceeds configured limit 2/)
  ensure
    Smith.config.parallel_branch_limit = original_limit
  end

  it "routes through on_failure when a parallel branch fails" do
    workflow = with_stubbed_class("SpecParallelFailureWorkflow", workflow_class) do
      initial_state :idle
      state :running
      state :done
      state :failed

      transition :fan_out, from: :idle, to: :running do
        execute :spec_parallel_agent, parallel: true, count: 3
        on_failure :fail
      end

      transition :finish, from: :running, to: :done
    end.new

    workflow.define_singleton_method(:execute_transition_body) do |_transition, prepared_input: nil|
      @parallel_calls ||= 0
      @parallel_calls += 1
      raise Smith::WorkflowError, "branch failed" if @parallel_calls == 1

      :ok
    end

    result = workflow.run!

    expect(workflow.state).to eq(:failed)
    expect(result.state).to eq(:failed)
    expect(result.steps.length).to eq(1)
    expect(result.steps.first[:transition]).to eq(:fan_out)
    expect(result.steps.first[:error]).to be_a(workflow_error)
  end

  it "does not surface successful branch outputs when a parallel step fails" do
    workflow = with_stubbed_class("SpecParallelDiscardWorkflow", workflow_class) do
      initial_state :idle
      state :running
      state :done
      state :failed

      transition :fan_out, from: :idle, to: :running do
        execute :spec_parallel_agent, parallel: true, count: 3
        on_failure :fail
      end

      transition :finish, from: :running, to: :done
    end.new

    workflow.define_singleton_method(:execute_transition_body) do |_transition, prepared_input: nil|
      @parallel_calls ||= 0
      @parallel_calls += 1
      return :ok if @parallel_calls == 1

      raise Smith::WorkflowError, "branch failed"
    end

    result = workflow.run!

    expect(result.state).to eq(:failed)
    expect(result.output).to be_nil
    expect(result.steps.first).not_to have_key(:output)
    expect(result.steps.first[:error]).to be_a(workflow_error)
  end

  it "cancels sibling branches cooperatively at the next check boundary" do
    cancellation_observations = Queue.new
    started_barrier = Concurrent::CountDownLatch.new(3)
    call_counter = Concurrent::AtomicFixnum.new(0)

    workflow = with_stubbed_class("SpecParallelCoopCancelWorkflow", workflow_class) do
      initial_state :idle
      state :done
      state :failed

      transition :fan_out, from: :idle, to: :done do
        execute :spec_parallel_agent, parallel: true, count: 3
        on_failure :fail
      end
    end.new

    workflow.define_singleton_method(:execute_transition_body) do |_transition, prepared_input: nil|
      branch = call_counter.increment
      started_barrier.count_down
      started_barrier.wait(1)

      if branch == 1
        raise Smith::WorkflowError, "branch failed"
      end

      sleep 0.05
      :ok
    end

    workflow.define_singleton_method(:check_cancellation!) do |signal|
      if signal.cancelled?
        cancellation_observations << Thread.current.object_id
        raise Smith::WorkflowError, "cancelled"
      end
    end

    result = workflow.run!

    expect(result.state).to eq(:failed)

    observed = []
    observed << cancellation_observations.pop until cancellation_observations.empty?
    expect(observed.length).to be >= 1
  end

  it "does not interrupt in-flight branch work but discards its output on step failure" do
    branch_outputs = Queue.new
    call_counter = Concurrent::AtomicFixnum.new(0)

    workflow = with_stubbed_class("SpecParallelInflightWorkflow", workflow_class) do
      initial_state :idle
      state :done
      state :failed

      transition :fan_out, from: :idle, to: :done do
        execute :spec_parallel_agent, parallel: true, count: 2
        on_failure :fail
      end
    end.new

    workflow.define_singleton_method(:execute_transition_body) do |_transition, prepared_input: nil|
      branch = call_counter.increment

      if branch == 1
        sleep 0.05
        branch_outputs << :branch_0_completed
        :branch_0_result
      else
        raise Smith::WorkflowError, "branch failed"
      end
    end

    result = workflow.run!

    expect(result.state).to eq(:failed)
    expect(result.output).to be_nil

    finished = []
    finished << branch_outputs.pop until branch_outputs.empty?
    expect(finished).to include(:branch_0_completed)
  end

  it "reuses the prepared input for each parallel branch execution" do
    manager = with_stubbed_class("SpecParallelPreparedInputContext", context_class) do
      session_strategy :observation_masking, window: 1

      inject_state do |persisted|
        "summary: #{persisted[:current_findings]}"
      end
    end

    seen_branch_inputs = []
    agent = with_stubbed_class("SpecParallelPreparedInputAgent", agent_class) do
      register_as :spec_parallel_prepared_input_agent
      model "gpt-5-mini"
    end

    allow(agent).to receive(:chat) do
      chat = Object.new
      messages = []

      chat.define_singleton_method(:add_message) do |message|
        messages << message
      end
      chat.define_singleton_method(:complete) do
        seen_branch_inputs << messages.dup
        Struct.new(:content).new("ok")
      end

      chat
    end

    workflow = with_stubbed_class("SpecParallelPreparedInputWorkflow", workflow_class) do
      context_manager manager
      initial_state :idle
      state :done

      transition :fan_out, from: :idle, to: :done do
        execute :spec_parallel_prepared_input_agent, parallel: true, count: 2
      end
    end.new(context: { current_findings: "stable" })

    workflow.instance_variable_set(
      :@session_messages,
      [
        { role: :user, content: "older" },
        { role: :assistant, content: "middle" },
        { role: :user, content: "latest" }
      ]
    )

    result = workflow.run!

    expect(result.state).to eq(:done)
    expect(seen_branch_inputs).to eq(
      [
        [
          { role: :system, content: "[smith:injected-state]\nsummary: stable" },
          { role: :user, content: "latest" }
        ],
        [
          { role: :system, content: "[smith:injected-state]\nsummary: stable" },
          { role: :user, content: "latest" }
        ]
      ]
    )
  end

  it "applies attached tool guardrails inside parallel branch threads" do
    observed = Queue.new

    guardrailed_tool = with_stubbed_class("SpecParallelGuardrailedTool", tool_class) do
      def perform(**kwargs)
        kwargs
      end
    end
    tool_name = guardrailed_tool.new.name.to_sym

    workflow_guardrails = with_stubbed_class("SpecParallelToolGuardrails", guardrails_class) do
      define_method(:capture_tool_payload) do |payload|
        observed << payload
      end

      tool :capture_tool_payload, on: [tool_name]
    end

    with_stubbed_class("SpecParallelToolGuardrailAgent", agent_class) do
      register_as :spec_parallel_tool_guardrail_agent
    end

    workflow = with_stubbed_class("SpecParallelToolGuardrailWorkflow", workflow_class) do
      initial_state :idle
      state :done
      guardrails workflow_guardrails

      transition :fan_out, from: :idle, to: :done do
        execute :spec_parallel_tool_guardrail_agent, parallel: true, count: 2
      end
    end.new

    workflow.define_singleton_method(:execute_transition_body) do |_transition, prepared_input: nil|
      guardrailed_tool.new.execute(context: @context, branch: Thread.current.object_id, prepared_input: prepared_input)
      :ok
    end

    result = workflow.run!

    expect(result.state).to eq(:done)
    observed_payloads = []
    observed_payloads << observed.pop until observed.empty?

    expect(observed_payloads.length).to eq(2)
    expect(observed_payloads).to all(include(context: {}))
    expect(observed_payloads).to all(include(:branch, :prepared_input))
  end

  it "reserves and reconciles workflow budget for successful parallel branches" do
    workflow = with_stubbed_class("SpecParallelBudgetSuccessWorkflow", workflow_class) do
      initial_state :idle
      state :done
      budget total_tokens: 100, total_cost: 1.0

      transition :fan_out, from: :idle, to: :done do
        execute :spec_parallel_agent, parallel: true, count: 2
      end
    end.new

    observed = Queue.new
    ledger = workflow.ledger

    allow(ledger).to receive(:reserve_many!).and_wrap_original do |original, reservations|
      reservations.each { |key, amount| observed << [:reserve, key, amount] }
      original.call(reservations)
    end
    allow(ledger).to receive(:reconcile_many!).and_wrap_original do |original, reservation, actual:|
      reservation.amounts.each { |key, amount| observed << [:reconcile, key, amount, actual.fetch(key)] }
      original.call(reservation, actual:)
    end
    allow(ledger).to receive(:release_many!).and_wrap_original do |original, reservation|
      reservation.amounts.each { |key, amount| observed << [:release, key, amount] }
      original.call(reservation)
    end

    result = workflow.run!

    expect(result.state).to eq(:done)
    entries = []
    entries << observed.pop until observed.empty?

    reserve_entries = entries.select { |entry| entry[0] == :reserve }
    reconcile_entries = entries.select { |entry| entry[0] == :reconcile }
    release_entries = entries.select { |entry| entry[0] == :release }

    expect(reserve_entries).to contain_exactly(
      [:reserve, :total_tokens, 50],
      [:reserve, :total_cost, 0.5],
      [:reserve, :total_tokens, 50],
      [:reserve, :total_cost, 0.5]
    )
    expect(reconcile_entries).to contain_exactly(
      [:reconcile, :total_tokens, 50, 0],
      [:reconcile, :total_cost, 0.5, 0],
      [:reconcile, :total_tokens, 50, 0],
      [:reconcile, :total_cost, 0.5, 0]
    )
    expect(release_entries).to eq([])
  end

  it "releases reserved workflow budget when a parallel branch fails" do
    workflow = with_stubbed_class("SpecParallelBudgetFailureWorkflow", workflow_class) do
      initial_state :idle
      state :running
      state :failed
      budget total_tokens: 100, total_cost: 1.0

      transition :fan_out, from: :idle, to: :running do
        execute :spec_parallel_agent, parallel: true, count: 2
        on_failure :fail
      end
    end.new

    workflow.define_singleton_method(:execute_transition_body) do |_transition, prepared_input: nil|
      @parallel_calls ||= 0
      @parallel_calls += 1
      raise Smith::WorkflowError, "branch failed" if @parallel_calls == 1

      sleep 0.01
      :ok
    end

    observed = Queue.new
    ledger = workflow.ledger

    allow(ledger).to receive(:reserve_many!).and_wrap_original do |original, reservations|
      reservations.each { |key, amount| observed << [:reserve, key, amount] }
      original.call(reservations)
    end
    allow(ledger).to receive(:reconcile_many!).and_wrap_original do |original, reservation, actual:|
      reservation.amounts.each { |key, amount| observed << [:reconcile, key, amount, actual.fetch(key)] }
      original.call(reservation, actual:)
    end
    allow(ledger).to receive(:release_many!).and_wrap_original do |original, reservation|
      reservation.amounts.each { |key, amount| observed << [:release, key, amount] }
      original.call(reservation)
    end

    result = workflow.run!

    expect(result.state).to eq(:failed)
    entries = []
    entries << observed.pop until observed.empty?

    reserve_entries = entries.select { |entry| entry[0] == :reserve }
    release_entries = entries.select { |entry| entry[0] == :release }

    expect(reserve_entries.length).to be >= 2
    expect(release_entries.length).to be >= 2
    expect(release_entries).to all(satisfy { |entry| entry[2] >= 0 })
  end

  it "uses a token reservation floor of 1 for positive limits smaller than branch count" do
    workflow = with_stubbed_class("SpecParallelBudgetFloorWorkflow", workflow_class) do
      initial_state :idle
      state :running
      state :failed
      budget total_tokens: 1

      transition :fan_out, from: :idle, to: :running do
        execute :spec_parallel_agent, parallel: true, count: 2
        on_failure :fail
      end
    end.new

    observed = Queue.new
    ledger = workflow.ledger

    allow(ledger).to receive(:reserve!).and_wrap_original do |original, key, amount|
      observed << [:reserve, key, amount]
      original.call(key, amount)
    end

    workflow.define_singleton_method(:execute_transition_body) do |_transition, prepared_input: nil|
      sleep 0.05
      super(_transition, prepared_input: prepared_input)
    end

    result = workflow.run!

    expect(result.state).to eq(:failed)
    entries = []
    entries << observed.pop until observed.empty?

    reserve_entries = entries.select { |entry| entry[0] == :reserve }
    expect(reserve_entries).to include([:reserve, :total_tokens, 1])
    expect(reserve_entries.length).to be >= 2
  end

  it "denies a parallel branch before branch work when reservation would exceed budget" do
    budget_exceeded = require_const("Smith::BudgetExceeded")

    workflow = with_stubbed_class("SpecParallelBudgetDeniedWorkflow", workflow_class) do
      initial_state :idle
      state :running
      state :failed
      budget total_tokens: 1

      transition :fan_out, from: :idle, to: :running do
        execute :spec_parallel_agent, parallel: true, count: 2
        on_failure :fail
      end
    end.new

    reservation_failures = Queue.new
    ledger = workflow.ledger

    allow(ledger).to receive(:reserve!).and_wrap_original do |original, key, amount|
      original.call(key, amount)
    rescue budget_exceeded => e
      reservation_failures << [key, amount, e.class]
      raise
    end

    executed = Queue.new
    workflow.define_singleton_method(:execute_transition_body) do |_transition, prepared_input: nil|
      executed << :ran
      sleep 0.05
      super(_transition, prepared_input: prepared_input)
    end

    result = workflow.run!

    expect(result.state).to eq(:failed)
    expect(workflow.state).to eq(:failed)
    expect(executed.size).to eq(1)
    failures = []
    failures << reservation_failures.pop until reservation_failures.empty?
    expect(failures).to include([:total_tokens, 1, budget_exceeded])
  end

  it "reconciles parallel branch reservations with response token metadata" do
    agent = with_stubbed_class("SpecParallelBudgetTokenAgent", agent_class) do
      register_as :spec_parallel_budget_token_agent
      model "gpt-5-mini"
    end

    allow(agent).to receive(:chat) do
      chat = Object.new
      chat.define_singleton_method(:add_message) { |_message| nil }
      chat.define_singleton_method(:complete) do
        Struct.new(:content, :input_tokens, :output_tokens).new("ok", 7, 5)
      end
      chat
    end

    workflow = with_stubbed_class("SpecParallelBudgetTokenWorkflow", workflow_class) do
      initial_state :idle
      state :done
      budget total_tokens: 100

      transition :fan_out, from: :idle, to: :done do
        execute :spec_parallel_budget_token_agent, parallel: true, count: 2
      end
    end.new

    observed = Queue.new
    ledger = workflow.ledger

    allow(ledger).to receive(:reconcile!).and_wrap_original do |original, reservation, actual_amount|
      key, reserved_amount = reservation.amounts.first
      observed << [:reconcile, key, reserved_amount, actual_amount]
      original.call(reservation, actual_amount)
    end

    result = workflow.run!

    expect(result.state).to eq(:done)
    entries = []
    entries << observed.pop until observed.empty?

    reconcile_entries = entries.select { |entry| entry[0] == :reconcile }
    expect(reconcile_entries).to contain_exactly(
      [:reconcile, :total_tokens, 50, 12],
      [:reconcile, :total_tokens, 50, 12]
    )
  end

  it "bases parallel branch estimates on remaining budget after prior serial consumption" do
    serial_agent = with_stubbed_class("SpecMixedBudgetSerialAgent", agent_class) do
      register_as :spec_mixed_budget_serial_agent
      model "gpt-5-mini"
    end

    parallel_agent = with_stubbed_class("SpecMixedBudgetParallelAgent", agent_class) do
      register_as :spec_mixed_budget_parallel_agent
      model "gpt-5-mini"
    end

    serial_chat = Object.new
    serial_chat.define_singleton_method(:add_message) { |_message| nil }
    serial_chat.define_singleton_method(:complete) do
      Struct.new(:content, :input_tokens, :output_tokens).new("serial", 20, 15)
    end

    parallel_chat = Object.new
    parallel_chat.define_singleton_method(:add_message) { |_message| nil }
    parallel_chat.define_singleton_method(:complete) do
      Struct.new(:content, :input_tokens, :output_tokens).new("parallel", 0, 0)
    end

    allow(serial_agent).to receive(:chat).and_return(serial_chat)
    allow(parallel_agent).to receive(:chat).and_return(parallel_chat)

    workflow = with_stubbed_class("SpecMixedBudgetWorkflow", workflow_class) do
      initial_state :idle
      state :serial_done
      state :done
      budget total_tokens: 50_000

      transition :serial_step, from: :idle, to: :serial_done do
        execute :spec_mixed_budget_serial_agent
        on_success :fan_out
      end

      transition :fan_out, from: :serial_done, to: :done do
        execute :spec_mixed_budget_parallel_agent, parallel: true, count: 2
      end
    end.new

    observed = Queue.new
    ledger = workflow.ledger

    allow(ledger).to receive(:reserve!).and_wrap_original do |original, key, amount|
      observed << [:reserve, key, amount]
      original.call(key, amount)
    end

    result = workflow.run!

    expect(result.state).to eq(:done)
    entries = []
    entries << observed.pop until observed.empty?

    total_token_reserves = entries.select { |entry| entry[0] == :reserve && entry[1] == :total_tokens }
    expect(total_token_reserves).to include([:reserve, :total_tokens, 50_000])
    expect(total_token_reserves.count([:reserve, :total_tokens, 24_982])).to eq(2)
  end

  it "enforces agent-only token_limit per parallel branch invocation without a workflow budget" do
    budget_ledger_class = require_const("Smith::Budget::Ledger")

    agent = with_stubbed_class("SpecParallelAgentOnlyTokenBudgetAgent", agent_class) do
      register_as :spec_parallel_agent_only_token_budget_agent
      model "gpt-5-mini"
      budget token_limit: 10
    end

    allow(agent).to receive(:chat) do
      chat = Object.new
      chat.define_singleton_method(:add_message) { |_message| nil }
      chat.define_singleton_method(:complete) do
        Struct.new(:content, :input_tokens, :output_tokens).new("ok", 7, 5)
      end
      chat
    end

    observed = Queue.new
    created_ledgers = []

    allow(budget_ledger_class).to receive(:new).and_wrap_original do |original, *args, **kwargs|
      ledger = original.call(*args, **kwargs)
      if ledger.limits == { token_limit: 10 }
        created_ledgers << ledger
        allow(ledger).to receive(:reserve!).and_wrap_original do |inner, key, amount|
          observed << [:reserve, ledger.object_id, key, amount]
          inner.call(key, amount)
        end
        allow(ledger).to receive(:reconcile!).and_wrap_original do |inner, reservation, actual_amount|
          key, reserved_amount = reservation.amounts.first
          observed << [:reconcile, ledger.object_id, key, reserved_amount, actual_amount]
          inner.call(reservation, actual_amount)
        end
      end
      ledger
    end

    workflow = with_stubbed_class("SpecParallelAgentOnlyTokenBudgetWorkflow", workflow_class) do
      initial_state :idle
      state :done

      transition :fan_out, from: :idle, to: :done do
        execute :spec_parallel_agent_only_token_budget_agent, parallel: true, count: 2
      end
    end.new

    result = workflow.run!

    expect(result.state).to eq(:done)
    expect(workflow.ledger).to be_nil
    expect(created_ledgers.length).to be >= 2

    entries = []
    entries << observed.pop until observed.empty?

    reserve_entries = entries.select { |entry| entry[0] == :reserve }
    reconcile_entries = entries.select { |entry| entry[0] == :reconcile }
    used_ledger_ids = (reserve_entries + reconcile_entries).map { |entry| entry[1] }.uniq

    expect(used_ledger_ids.length).to eq(2)
    expect(reserve_entries).to contain_exactly(
      [:reserve, used_ledger_ids[0], :token_limit, 10],
      [:reserve, used_ledger_ids[1], :token_limit, 10]
    )
    expect(reconcile_entries).to contain_exactly(
      [:reconcile, used_ledger_ids[0], :token_limit, 10, 12],
      [:reconcile, used_ledger_ids[1], :token_limit, 10, 12]
    )
  end

  it "enforces agent-only cost per parallel branch invocation without a workflow budget" do
    budget_ledger_class = require_const("Smith::Budget::Ledger")
    original_pricing = Smith.config.pricing

    Smith.configure do |config|
      config.pricing = {
        "gpt-5-mini" => {
          input_cost_per_token: 0.01,
          output_cost_per_token: 0.02
        }
      }
    end

    agent = with_stubbed_class("SpecParallelAgentOnlyCostBudgetAgent", agent_class) do
      register_as :spec_parallel_agent_only_cost_budget_agent
      model "gpt-5-mini"
      budget cost: 0.20
    end

    allow(agent).to receive(:chat) do
      chat = Object.new
      chat.define_singleton_method(:add_message) { |_message| nil }
      chat.define_singleton_method(:complete) do
        Struct.new(:content, :input_tokens, :output_tokens).new("ok", 7, 5)
      end
      chat
    end

    observed = Queue.new
    created_ledgers = []

    allow(budget_ledger_class).to receive(:new).and_wrap_original do |original, *args, **kwargs|
      ledger = original.call(*args, **kwargs)
      if ledger.limits == { total_cost: 0.20 }
        created_ledgers << ledger
        allow(ledger).to receive(:reserve!).and_wrap_original do |inner, key, amount|
          observed << [:reserve, ledger.object_id, key, amount]
          inner.call(key, amount)
        end
        allow(ledger).to receive(:reconcile!).and_wrap_original do |inner, reservation, actual_amount|
          key, reserved_amount = reservation.amounts.first
          observed << [:reconcile, ledger.object_id, key, reserved_amount, actual_amount]
          inner.call(reservation, actual_amount)
        end
      end
      ledger
    end

    workflow = with_stubbed_class("SpecParallelAgentOnlyCostBudgetWorkflow", workflow_class) do
      initial_state :idle
      state :done

      transition :fan_out, from: :idle, to: :done do
        execute :spec_parallel_agent_only_cost_budget_agent, parallel: true, count: 2
      end
    end.new

    result = workflow.run!

    expect(result.state).to eq(:done)
    expect(workflow.ledger).to be_nil
    expect(created_ledgers.length).to be >= 2

    entries = []
    entries << observed.pop until observed.empty?

    reserve_entries = entries.select { |entry| entry[0] == :reserve }
    reconcile_entries = entries.select { |entry| entry[0] == :reconcile }
    used_ledger_ids = (reserve_entries + reconcile_entries).map { |entry| entry[1] }.uniq

    expect(used_ledger_ids.length).to eq(2)
    expect(reserve_entries).to contain_exactly(
      [:reserve, used_ledger_ids[0], :total_cost, 0.20],
      [:reserve, used_ledger_ids[1], :total_cost, 0.20]
    )
    expect(reconcile_entries).to contain_exactly(
      [:reconcile, used_ledger_ids[0], :total_cost, 0.20, 0.17],
      [:reconcile, used_ledger_ids[1], :total_cost, 0.20, 0.17]
    )
  ensure
    Smith.configure { |config| config.pricing = original_pricing }
  end

  it "treats agent-only parallel budgets as per-branch ledgers rather than one shared pool" do
    budget_ledger_class = require_const("Smith::Budget::Ledger")

    agent = with_stubbed_class("SpecParallelPerBranchAgentBudgetAgent", agent_class) do
      register_as :spec_parallel_per_branch_agent_budget_agent
      model "gpt-5-mini"
      budget token_limit: 10
    end

    allow(agent).to receive(:chat) do
      chat = Object.new
      chat.define_singleton_method(:add_message) { |_message| nil }
      chat.define_singleton_method(:complete) do
        Struct.new(:content, :input_tokens, :output_tokens).new("ok", 1, 0)
      end
      chat
    end

    created_ledgers = []

    allow(budget_ledger_class).to receive(:new).and_wrap_original do |original, *args, **kwargs|
      ledger = original.call(*args, **kwargs)
      created_ledgers << ledger if ledger.limits == { token_limit: 10 }
      ledger
    end

    workflow = with_stubbed_class("SpecParallelPerBranchAgentBudgetWorkflow", workflow_class) do
      initial_state :idle
      state :done

      transition :fan_out, from: :idle, to: :done do
        execute :spec_parallel_per_branch_agent_budget_agent, parallel: true, count: 2
      end
    end.new

    result = workflow.run!

    expect(result.state).to eq(:done)

    used_ledgers = created_ledgers.select { |ledger| ledger.consumed[:token_limit] == 1 }

    expect(used_ledgers.length).to eq(2)
    expect(used_ledgers.map(&:object_id).uniq.length).to eq(2)
    expect(used_ledgers.map { |ledger| ledger.consumed[:token_limit] }).to eq([1, 1])
  end

  it "captures tool results from parallel branches without loss" do
    tool_class = require_const("Smith::Tool")

    capturing_tool = with_stubbed_class("SpecParallelCaptureTool", tool_class) do
      capture_result { |kwargs, _result| { branch: kwargs[:branch_id] } }
      def perform(branch_id:, **) = "result-#{branch_id}"
    end

    agent = with_stubbed_class("SpecParallelCaptureAgent", agent_class) do
      register_as :spec_parallel_capture_agent
      model "gpt-5-mini"
    end

    branch_index = Concurrent::AtomicFixnum.new(0)
    allow(agent).to receive(:chat) do
      idx = branch_index.increment
      tool_instance = capturing_tool.new
      chat = Object.new
      chat.define_singleton_method(:add_message) { |_| nil }
      chat.define_singleton_method(:complete) do
        tool_instance.execute(branch_id: idx)
        Struct.new(:content).new("branch-#{idx}")
      end
      chat
    end

    workflow = with_stubbed_class("SpecParallelCaptureWorkflow", workflow_class) do
      initial_state :idle
      state :done

      transition :fan_out, from: :idle, to: :done do
        execute :spec_parallel_capture_agent, parallel: true, count: 3
      end
    end.new

    result = workflow.run!

    expect(result.state).to eq(:done)
    expect(result.tool_results.length).to eq(3)

    captured_branches = result.tool_results.map { |tr| tr[:captured][:branch] }.sort
    expect(captured_branches).to eq([1, 2, 3])
  end

  it "gives strict capture uncertainty precedence over a retryable sibling failure" do
    effects = Concurrent::AtomicFixnum.new(0)
    calls = Concurrent::AtomicFixnum.new(0)
    barrier = Concurrent::CyclicBarrier.new(2)
    uncertain_tool = with_stubbed_class("SpecParallelUncertainCaptureTool", tool_class) do
      capture_result(strict: true) { raise "projection failed" }
      define_method(:perform) do |**_kwargs|
        effects.increment
        :performed
      end
    end
    agent = with_stubbed_class("SpecParallelUncertainCaptureAgent", agent_class) do
      register_as :spec_parallel_uncertain_capture_agent
      model "gpt-5-mini"
    end
    allow(agent).to receive(:chat) do
      branch = calls.increment
      Object.new.tap do |chat|
        chat.define_singleton_method(:add_message) { |_message| nil }
        chat.define_singleton_method(:complete) do
          barrier.wait
          raise Smith::AgentError, "sibling failed first" if branch == 1

          sleep(0.02)
          uncertain_tool.new.execute
        end
      end
    end
    workflow = with_stubbed_class("SpecParallelUncertainCaptureWorkflow", workflow_class) do
      initial_state :idle
      state :done
      state :failed
      transition :review, from: :idle, to: :done do
        execute :spec_parallel_uncertain_capture_agent, parallel: true, count: 2
        retry_on StandardError, attempts: 2
        on_failure :fail
      end
    end.new

    result = workflow.run!

    expect(result).to be_failed
    expect(result.last_error).to be_a(Smith::ToolCaptureFailed)
    expect(effects.value).to eq(1)
    expect(calls.value).to eq(2)
  end

  it "preserves strict capture uncertainty through nested parallel arbitration" do
    barrier = Concurrent::CyclicBarrier.new(2)
    uncertainty = Smith::ToolCaptureFailed.new(tool_name: :nested, reason: :collector_failed)
    nested = proc do |_outer_signal|
      Smith::Workflow::Parallel.execute(
        branches: [
          proc do |_signal|
            barrier.wait
            raise Smith::AgentError, "nested sibling failed"
          end,
          proc do |_signal|
            barrier.wait
            sleep(0.02)
            raise uncertainty
          end
        ]
      )
    end

    expect do
      Smith::Workflow::Parallel.execute(branches: [nested, proc { |_signal| :ok }])
    end.to raise_error(Smith::ToolCaptureFailed, uncertainty.message)
  end

  [
    ["fatal before ordinary", 0, 0.02, Smith::AgentError.new("ordinary")],
    ["fatal after ordinary", 0.02, 0, Smith::AgentError.new("ordinary")],
    [
      "fatal before strict capture uncertainty",
      0,
      0.02,
      Smith::ToolCaptureFailed.new(tool_name: :search, reason: :collector_failed)
    ],
    [
      "fatal after strict capture uncertainty",
      0.02,
      0,
      Smith::ToolCaptureFailed.new(tool_name: :search, reason: :collector_failed)
    ]
  ].each do |description, fatal_delay, sibling_delay, sibling_error|
    it "preserves a process-fatal root branch #{description}" do
      barrier = Concurrent::CyclicBarrier.new(2)
      fatal_branch = proc do |_signal|
        barrier.wait
        sleep(fatal_delay)
        raise Interrupt, "shutdown"
      end
      sibling_branch = proc do |_signal|
        barrier.wait
        sleep(sibling_delay)
        raise sibling_error
      end

      expect do
        Smith::Workflow::Parallel.execute(branches: [fatal_branch, sibling_branch])
      end.to raise_error(Interrupt, "shutdown")
    end
  end

  it "captures all entries from 50 parallel branches without loss" do
    tool_class = require_const("Smith::Tool")

    capturing_tool = with_stubbed_class("SpecHighBranchCaptureTool", tool_class) do
      capture_result { |kwargs, _result| { branch: kwargs[:branch_id] } }
      def perform(branch_id:, **) = "result-#{branch_id}"
    end

    agent = with_stubbed_class("SpecHighBranchCaptureAgent", agent_class) do
      register_as :spec_high_branch_capture_agent
      model "gpt-5-mini"
    end

    branch_index = Concurrent::AtomicFixnum.new(0)
    allow(agent).to receive(:chat) do
      idx = branch_index.increment
      tool_instance = capturing_tool.new
      chat = Object.new
      chat.define_singleton_method(:add_message) { |_| nil }
      chat.define_singleton_method(:complete) do
        tool_instance.execute(branch_id: idx)
        Struct.new(:content).new("branch-#{idx}")
      end
      chat
    end

    workflow = with_stubbed_class("SpecHighBranchCaptureWorkflow", workflow_class) do
      initial_state :idle
      state :done

      transition :fan_out, from: :idle, to: :done do
        execute :spec_high_branch_capture_agent, parallel: true, count: 50
      end
    end.new

    result = workflow.run!

    expect(result.state).to eq(:done)
    expect(result.tool_results.length).to eq(50)
    expect(result.tool_results.map { |tr| tr[:captured][:branch] }.sort).to eq((1..50).to_a)
  end
end
