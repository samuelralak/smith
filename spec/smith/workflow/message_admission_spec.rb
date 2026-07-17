# frozen_string_literal: true

RSpec.describe Smith::Workflow::MessageAdmission do
  let(:workflow_class) do
    Class.new(Smith::Workflow) do
      initial_state :idle
      state :done
      transition(:finish, from: :idle, to: :done) { compute { |_step| :done } }
    end
  end

  it "appends one canonical message and returns an immutable digest witness" do
    workflow = workflow_class.new

    admission = workflow.append_session_messages!(role: :user, content: "Continue.")

    expect(admission).to be_frozen
    expect(admission.messages).to be_frozen
    expect(admission.messages.first).to be_frozen
    expect(admission.message_digest).to be_frozen
    expect(admission.message_count).to eq(1)
    expect(admission.messages).to eq([{ "content" => "Continue.", "role" => "user" }])
    expect(admission.message_digest).to eq(Digest::SHA256.hexdigest(JSON.generate(admission.messages)))
    expect(workflow.session_messages).to eq(admission.messages)
  end

  it "owns its canonical messages and digest when constructed directly" do
    source = [{ role: :user, content: { text: "Original" } }]
    admission = described_class.new(messages: source)

    source.first.fetch(:content)[:text] = "Changed"

    expect(admission.messages.dig(0, "content", "text")).to eq("Original")
    expect { admission.message_digest.replace("0" * 64) }.to raise_error(FrozenError)
    expect do
      described_class.new(messages: source, message_digest: "0" * 64)
    end.to raise_error(Dry::Struct::Error)
  end

  it "canonicalizes equivalent key and role representations to the same digest" do
    symbol_admission = workflow_class.new.append_session_messages!(role: :user, content: "Hello")
    string_admission = workflow_class.new.append_session_messages!("content" => "Hello", "role" => "user")

    expect(symbol_admission.message_digest).to eq(string_admission.message_digest)
  end

  it "accepts a bounded batch and preserves message order" do
    workflow = workflow_class.new
    messages = [
      { role: :user, content: "Question" },
      { role: :assistant, content: "Answer" },
      { role: :tool, content: { result: [1, true, nil] }, tool_call_id: "call-1" }
    ]

    admission = workflow.append_session_messages!(messages)

    expect(admission.message_count).to eq(3)
    expect(workflow.session_messages.map { _1.fetch("role") }).to eq(%w[user assistant tool])
  end

  it "does not retain mutable aliases from caller input" do
    content = { "parts" => [{ "text" => "Original" }] }
    message = { role: :user, content: }
    workflow = workflow_class.new

    admission = workflow.append_session_messages!(message)
    content.fetch("parts").first["text"] = "Changed"

    expect(admission.messages.dig(0, "content", "parts", 0, "text")).to eq("Original")
    expect(admission.messages.dig(0, "content", "parts")).to be_frozen
  end

  it "owns hostile String subclasses through core String operations" do
    hostile_string = Class.new(String) do
      def bytesize = 0
      def dup = self
      def freeze = self
    end
    source = hostile_string.new("Original")
    workflow = workflow_class.new

    admission = workflow.append_session_messages!(role: :user, content: source)
    source.replace("Changed")
    content = admission.messages.dig(0, "content")

    expect(content).to be_instance_of(String)
    expect(content).to be_frozen
    expect(content).to eq("Original")
    expect(admission.message_digest).to eq(Digest::SHA256.hexdigest(JSON.generate(admission.messages)))
  end

  it "does not trust an overridden String byte count" do
    hostile_string = Class.new(String) do
      def bytesize = 0
    end
    oversized = hostile_string.new("x" * (Smith::Workflow::MessageBatch::MAX_BYTES + 1))

    expect do
      workflow_class.new.append_session_messages!(role: :user, content: oversized)
    end.to raise_error(Smith::WorkflowError, /maximum bytes/)
  end

  it "survives a public persistence and restore round trip" do
    adapter = Smith::PersistenceAdapters::Memory.new
    workflow = workflow_class.new
    workflow.append_session_messages!(role: :user, content: "Persist me")

    workflow.persist!("message-admission", adapter:)
    restored = workflow_class.restore("message-admission", adapter:)

    expect(restored.session_messages).to eq([{ role: "user", content: "Persist me" }])
  end

  it "does not expose mutable workflow history through readers or state snapshots" do
    workflow = workflow_class.new
    workflow.append_session_messages!(role: :user, content: { text: "Keep me" })

    workflow.session_messages.clear
    workflow.to_state.fetch(:session_messages).first.fetch("content")["text"] = "Changed"

    expect(workflow.session_messages).to eq(
      [{ "content" => { "text" => "Keep me" }, "role" => "user" }]
    )
  end

  it "does not retain nested aliases from restored state" do
    workflow = workflow_class.new
    state = workflow.to_state
    state[:session_messages] = [{ "role" => "user", "content" => { "text" => "Original" } }]

    restored = workflow_class.from_state(state)
    state.dig(:session_messages, 0, "content")["text"] = "Changed"

    expect(restored.session_messages.dig(0, :content, "text")).to eq("Original")
  end

  it "keeps admitted string-keyed messages visible to existing consumers" do
    admitted = described_class.new(
      messages: [
        { role: :system, content: "Policy" },
        { role: :assistant, content: "Answer" }
      ]
    ).messages

    masked = Smith::Context::ObservationMasking.apply(admitted, strategy: { window: 1 })
    injected = Smith::Context::StateInjection.inject(admitted, formatter: ->(_state) { "state" }, persisted: {})
    step = Smith::Workflow::DeterministicStep.new(
      context: {},
      session_messages: admitted,
      tool_results: [],
      state: :idle,
      transition_name: :finish
    )

    expect(masked.first.fetch("role")).to eq("system")
    expect(injected.count { (_1[:content] || _1["content"]).to_s.start_with?(Smith::Context::StateInjection::MARKER) })
      .to eq(1)
    expect(step.last_output).to eq("Answer")
  end

  it "serializes concurrent appends without losing a message" do
    workflow = workflow_class.new
    threads = 20.times.map do |index|
      Thread.new { workflow.append_session_messages!(role: :user, content: "message-#{index}") }
    end
    threads.each(&:join)

    expect(workflow.session_messages.length).to eq(20)
    expect(workflow.session_messages.map { _1.fetch("content") }.sort).to eq(
      20.times.map { "message-#{_1}" }.sort
    )
  end

  it "rejects admission while ordinary workflow execution is active" do
    entered = Queue.new
    release = Queue.new
    active_class = Class.new(Smith::Workflow) do
      initial_state :idle
      state :done
      transition(:finish, from: :idle, to: :done) do
        compute do |_step|
          entered << true
          release.pop
        end
      end
    end
    workflow = active_class.new
    execution = Thread.new { workflow.advance! }
    entered.pop

    expect do
      workflow.append_session_messages!(role: :user, content: "Too late")
    end.to raise_error(Smith::WorkflowError, /split-step persistence boundary is already active/)
  ensure
    release << true if release
    execution&.join
  end

  it "rejects admission while a prepared step boundary is active" do
    adapter = Smith::PersistenceAdapters::Memory.new
    strict_class = Class.new(workflow_class) do
      idempotency_mode :strict
      definition_digest Digest::SHA256.hexdigest("message-admission-boundary")
    end
    workflow = strict_class.new
    workflow.prepare_persisted_step!("prepared-message-admission", adapter:)

    expect do
      workflow.append_session_messages!(role: :user, content: "Too late")
    end.to raise_error(Smith::WorkflowError, /split-step persistence boundary is already active/)
  end

  it "does not mutate session history when validation fails" do
    workflow = workflow_class.new
    workflow.append_session_messages!(role: :user, content: "Existing")

    expect { workflow.append_session_messages!({ content: "Missing role" }) }
      .to raise_error(Smith::WorkflowError, /non-empty role/)
    expect(workflow.session_messages).to eq([{ "content" => "Existing", "role" => "user" }])
  end

  it "rejects empty and oversized batches" do
    workflow = workflow_class.new

    expect { workflow.append_session_messages!([]) }
      .to raise_error(Smith::WorkflowError, /must not be empty/)
    expect do
      workflow.append_session_messages!(Array.new(Smith::Workflow::MessageBatch::MAX_MESSAGES + 1) { { role: :user } })
    end.to raise_error(Smith::WorkflowError, /maximum count/)
  end

  it "does not trust overridable Array size or traversal methods" do
    deceptive_batch = Class.new(Array) do
      def length = 1
      def each = raise("overridden Array#each must not define admission")
    end.new(Array.new(Smith::Workflow::MessageBatch::MAX_MESSAGES + 1) { { role: :user } })

    expect { workflow_class.new.append_session_messages!(deceptive_batch) }
      .to raise_error(Smith::WorkflowError, /maximum count/)
  end

  it "rejects non-message batch members and missing roles" do
    workflow = workflow_class.new

    expect { workflow.append_session_messages!(["message"]) }
      .to raise_error(Smith::WorkflowError, /must be a Hash/)
    expect { workflow.append_session_messages!({ content: "missing" }) }
      .to raise_error(Smith::WorkflowError, /non-empty role/)
    expect { workflow.append_session_messages!({ role: "", content: "blank" }) }
      .to raise_error(Smith::WorkflowError, /non-empty role/)
    expect { workflow.append_session_messages!({ role: "  ", content: "blank" }) }
      .to raise_error(Smith::WorkflowError, /non-empty role/)
  end

  it "rejects duplicate canonical keys" do
    message = { role: :user, "role" => "assistant", content: "ambiguous" }

    expect { workflow_class.new.append_session_messages!(message) }
      .to raise_error(Smith::WorkflowError, /duplicate canonical Hash keys/)
  end

  it "rejects unsupported mutable values and invalid Hash keys" do
    workflow = workflow_class.new

    expect { workflow.append_session_messages!(role: :user, content: Object.new) }
      .to raise_error(Smith::WorkflowError, /unsupported value Object/)
    expect { workflow.append_session_messages!(role: :user, content: { 1 => "invalid" }) }
      .to raise_error(Smith::WorkflowError, /keys must be strings or symbols/)
  end

  it "rejects cycles in bounded time" do
    content = {}
    content[:cycle] = content

    expect { workflow_class.new.append_session_messages!(role: :user, content:) }
      .to raise_error(Smith::WorkflowError, /cyclic value/)
  end

  it "rejects non-finite floats and oversized integers" do
    workflow = workflow_class.new

    expect { workflow.append_session_messages!(role: :user, score: Float::INFINITY) }
      .to raise_error(Smith::WorkflowError, /non-finite Float/)
    expect { workflow.append_session_messages!(role: :user, counter: 2**63) }
      .to raise_error(Smith::WorkflowError, /signed 64-bit/)
  end

  it "rejects excessive depth before Ruby recursion becomes unsafe" do
    content = "leaf"
    (Smith::Workflow::MessageBatch::MAX_DEPTH + 1).times { content = [content] }

    expect { workflow_class.new.append_session_messages!(role: :user, content:) }
      .to raise_error(Smith::WorkflowError, /maximum depth/)
  end

  it "rejects oversized string data before append" do
    content = "x" * (Smith::Workflow::MessageBatch::MAX_BYTES + 1)

    expect { workflow_class.new.append_session_messages!(role: :user, content:) }
      .to raise_error(Smith::WorkflowError, /maximum bytes/)
  end

  it "applies the node ceiling to the whole batch rather than each message" do
    content = Array.new((Smith::Workflow::MessageBatch::MAX_NODES / 2) + 1, true)
    messages = [
      { role: :user, content: },
      { role: :user, content: }
    ]

    expect { workflow_class.new.append_session_messages!(messages) }
      .to raise_error(Smith::WorkflowError, /maximum size/)
  end

  it "bounds Hash traversal independently of overridable size and traversal methods" do
    oversized_hash = Class.new(Hash) do
      def length = 0
      def each_pair = raise("overridden Hash#each_pair must not define admission")
    end.new
    Smith::Workflow::MessageBatch::MAX_NODES.times { oversized_hash[_1.to_s] = true }

    expect do
      workflow_class.new.append_session_messages!(role: :user, content: oversized_hash)
    end.to raise_error(Smith::WorkflowError, /maximum size/)
  end

  it "detaches session history when a workflow is duplicated" do
    original = workflow_class.new
    original.append_session_messages!(role: :user, content: { text: "Original" })

    copy = original.dup
    copy.append_session_messages!(role: :user, content: "Copy only")
    copy.instance_variable_get(:@session_messages).first.fetch("content")["text"] = "Changed"

    expect(original.session_messages).to eq(
      [{ "content" => { "text" => "Original" }, "role" => "user" }]
    )
    expect(copy.session_messages.map { _1.fetch("content") }).to eq(
      [{ "text" => "Changed" }, "Copy only"]
    )
  end

  it "detaches the complete mutable runtime aggregate when duplicated" do
    duplicable_class = Class.new(Smith::Workflow) do
      initial_state :idle
      state :done
      budget total_tokens: 100
      transition(:finish, from: :idle, to: :done) { compute { |_step| :done } }
    end
    original = duplicable_class.new(context: { nested: { value: "Original" } })
    original.ledger.reserve!(:total_tokens, 10)
    original.ledger.reconcile!(:total_tokens, 10, 4)
    original.instance_variable_get(:@tool_results) << { captured: { value: "Original" } }
    original.instance_variable_get(:@usage_entries) << Smith::Workflow::UsageEntry.new(
      usage_id: "usage-original",
      model: "model-original"
    )

    copy = original.dup
    copy.instance_variable_get(:@context)[:nested][:value].replace("Copy")
    copy.instance_variable_get(:@tool_results).dig(0, :captured, :value).replace("Copy")
    copy.instance_variable_get(:@usage_entries).first.model.replace("model-copy")
    copy.ledger.reserve!(:total_tokens, 10)
    copy.ledger.reconcile!(:total_tokens, 10, 6)

    expect(original.to_state[:context]).to eq(nested: { value: "Original" })
    expect(original.to_state[:tool_results]).to eq([{ captured: { value: "Original" } }])
    expect(original.to_state[:usage_entries].first[:model]).to eq("model-original")
    expect(original.ledger.consumed[:total_tokens]).to eq(4)
    expect(copy.ledger.consumed[:total_tokens]).to eq(10)
    expect(copy.instance_variable_get(:@tool_results_mutex))
      .not_to equal(original.instance_variable_get(:@tool_results_mutex))
    expect(copy.instance_variable_get(:@usage_mutex))
      .not_to equal(original.instance_variable_get(:@usage_mutex))
    expect(copy.instance_variable_get(:@persisted_keys_mutex))
      .not_to equal(original.instance_variable_get(:@persisted_keys_mutex))
  end
end
