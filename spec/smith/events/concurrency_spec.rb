# frozen_string_literal: true

RSpec.describe "Smith::Events registry safety" do
  let(:events) { require_const("Smith::Events") }
  let(:step_completed) { require_const("Smith::Events::StepCompleted") }

  it "detaches a cancelled subscription from the registry instead of leaking it" do
    sub = events.on(step_completed) { nil }
    expect(events.subscriptions).to include(sub)

    sub.cancel

    expect(events.subscriptions).to be_empty
    expect(sub.cancelled?).to be(true)
  end

  it "cancel is idempotent" do
    sub = events.on(step_completed) { nil }

    sub.cancel
    expect { sub.cancel }.not_to raise_error
    expect(events.subscriptions).to be_empty
  end

  it "within no longer retains scoped subscriptions after the block" do
    events.within do |scope|
      scope.on(step_completed) { nil }
      scope.on(step_completed) { nil }
      expect(events.subscriptions.length).to eq(2)
    end

    expect(events.subscriptions).to be_empty
  end

  it "dispatches to subscriptions on modules mixed into the event instance via extend" do
    marker = Module.new
    observed = []
    events.on(marker) { observed << :marker }
    event = step_completed.new(transition: :finish, from: :idle, to: :done)
    event.extend(marker)

    events.emit(event)

    expect(observed).to eq([:marker])
  end

  it "dispatches immediate-value events through class ancestors" do
    observed = []
    events.on(Integer) { |event| observed << event }
    events.on(Symbol) { |event| observed << event }

    # Immediates have no singleton class; dispatch must fall back to class
    # ancestors instead of raising TypeError.
    events.emit(42)
    events.emit(:ping)

    expect(observed).to eq([42, :ping])
  end

  it "dispatches base-class and exact-class subscriptions in registration order" do
    base = require_const("Smith::Event")
    observed = []
    events.on(step_completed) { observed << :exact }
    events.on(base) { observed << :base }

    events.emit(step_completed.new(transition: :finish, from: :idle, to: :done))

    expect(observed).to eq(%i[exact base])
  end

  it "survives concurrent registration, emission, and cancellation" do
    start = Queue.new
    done = Queue.new
    received = Concurrent::AtomicFixnum.new(0)
    threads = 8.times.map do |index|
      Thread.new do
        start.pop
        subs = 25.times.map do
          events.on(step_completed) { received.increment }
        end

        events.emit(step_completed.new(transition: :finish, from: :idle, to: :done)) if index.even?

        subs.each(&:cancel)
        done << :ok
      end
    end

    8.times { start << :go }
    8.times { done.pop }
    threads.each { |thread| thread.join(5) || raise("registry thread did not finish") }

    expect(events.subscriptions).to be_empty
    # 4 emitting threads, at most 200 live subscriptions at any emit: more
    # than 800 dispatches would prove duplicate dispatch under contention.
    expect(received.value).to be <= 800
  end

  it "a handler may cancel its own subscription during dispatch without deadlock" do
    observed = []
    sub = events.on(step_completed) do |_event|
      observed << :ran
      sub.cancel
    end

    events.emit(step_completed.new(transition: :finish, from: :idle, to: :done))
    events.emit(step_completed.new(transition: :finish, from: :idle, to: :done))

    expect(observed).to eq([:ran])
    expect(events.subscriptions).to be_empty
  end
end
