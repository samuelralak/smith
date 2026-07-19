# frozen_string_literal: true

RSpec.describe "Smith budget ledger contract" do
  let(:ledger_class) { require_const("Smith::Budget::Ledger") }

  def build_ledger(limit:)
    ledger_class.new(limits: { tokens: limit })
  end

  it "reserves capacity against committed plus reserved usage" do
    ledger = build_ledger(limit: 100)

    expect { ledger.reserve!(:tokens, 40) }.not_to raise_error
    expect { ledger.reserve!(:tokens, 50) }.not_to raise_error
    expect { ledger.reserve!(:tokens, 11) }.to raise_error(require_const("Smith::BudgetExceeded"))
  end

  it "reconciles by consuming an exact reservation receipt" do
    ledger = build_ledger(limit: 100)
    reservation = ledger.reserve!(:tokens, 40)

    ledger.reconcile!(reservation, 25)

    expect { ledger.reserve!(:tokens, 75) }.not_to raise_error
    expect { ledger.reserve!(:tokens, 1) }.to raise_error(require_const("Smith::BudgetExceeded"))
  end

  it "releases an exact reservation receipt on failure" do
    ledger = build_ledger(limit: 100)
    reservation = ledger.reserve!(:tokens, 40)

    ledger.release!(reservation)

    expect { ledger.reserve!(:tokens, 100) }.not_to raise_error
    expect { ledger.reserve!(:tokens, 1) }.to raise_error(require_const("Smith::BudgetExceeded"))
  end

  it "does not mutate capacity when a reservation is denied" do
    ledger = build_ledger(limit: 100)
    reservation = ledger.reserve!(:tokens, 90)

    expect { ledger.reserve!(:tokens, 20) }.to raise_error(require_const("Smith::BudgetExceeded"))
    ledger.release!(reservation)

    expect { ledger.reserve!(:tokens, 100) }.not_to raise_error
  end

  it "fully frees the unused portion when actual usage is lower" do
    ledger = build_ledger(limit: 100)
    reservation = ledger.reserve!(:tokens, 60)

    ledger.reconcile!(reservation, 10)

    expect { ledger.reserve!(:tokens, 90) }.not_to raise_error
    expect { ledger.reserve!(:tokens, 1) }.to raise_error(require_const("Smith::BudgetExceeded"))
  end

  it "tracks dimensions independently" do
    ledger = ledger_class.new(limits: { tokens: 100, tool_calls: 2 })

    ledger.reserve!(:tokens, 100)
    expect { ledger.reserve!(:tool_calls, 2) }.not_to raise_error
    expect { ledger.reserve!(:tool_calls, 1) }.to raise_error(require_const("Smith::BudgetExceeded"))
  end

  it "reserves multiple dimensions atomically" do
    ledger = ledger_class.new(limits: { tokens: 10, cost: 1.0 })

    expect do
      ledger.reserve_many!(tokens: 5, cost: 2.0)
    end.to raise_error(require_const("Smith::BudgetExceeded"))

    expect { ledger.reserve!(:tokens, 10) }.not_to raise_error
    expect { ledger.reserve!(:tokens, 1) }.to raise_error(require_const("Smith::BudgetExceeded"))
  end

  it "rejects invalid values before mutating reservations" do
    [Float::NAN, -Float::INFINITY, -1].each do |invalid|
      ledger = build_ledger(limit: 10)

      expect { ledger.reserve_many!(tokens: invalid) }
        .to raise_error(ArgumentError, /finite and non-negative/)
      expect { ledger.reserve!(:tokens, 10) }.not_to raise_error
    end
  end

  it "rejects invalid reconciliation before mutation" do
    ledger = build_ledger(limit: 10)
    reservation = ledger.reserve!(:tokens, 10)

    expect { ledger.reconcile!(reservation, Float::NAN) }
      .to raise_error(ArgumentError, /finite and non-negative/)
    expect(ledger.remaining(:tokens)).to eq(0)

    ledger.release!(reservation)
    expect { ledger.reserve!(:tokens, 10) }.not_to raise_error
  end

  it "reconciles multiple dimensions atomically" do
    ledger = ledger_class.new(limits: { tokens: 10, cost: 5.0 })
    reservation = ledger.reserve_many!(tokens: 10, cost: 5.0)

    expect do
      ledger.reconcile_many!(reservation, actual: { tokens: 1, cost: Float::NAN })
    end.to raise_error(ArgumentError, /finite and non-negative/)
    expect(ledger.consumed).to eq({})
    expect(ledger.remaining(:tokens)).to eq(0)
    expect(ledger.remaining(:cost)).to eq(0)

    ledger.reconcile_many!(reservation, actual: { tokens: 1, cost: 0.5 })
    expect(ledger.consumed).to eq(tokens: 1, cost: 0.5)
  end

  it "releases multiple dimensions atomically" do
    ledger = ledger_class.new(limits: { tokens: 10, cost: 5.0 })
    reservation = ledger.reserve_many!(tokens: 10, cost: 5.0)

    ledger.release_many!(reservation)

    expect(ledger.remaining(:tokens)).to eq(10)
    expect(ledger.remaining(:cost)).to eq(5.0)
  end

  it "accounts for Float budgets through an exact internal decimal representation" do
    ledger = ledger_class.new(limits: { cost: 0.3 })
    reservations = 3.times.map { ledger.reserve!(:cost, 0.1) }

    expect(ledger.remaining(:cost)).to eq(0.0)
    reservations.each { ledger.release!(_1) }

    expect(ledger.remaining(:cost)).to eq(0.3)
    expect(ledger.consumed).to eq({})
  end

  it "isolates exact arithmetic from the host BigDecimal precision limit" do
    previous_limit = BigDecimal.limit
    BigDecimal.limit(2)
    ledger = ledger_class.new(limits: { cost: 1.0 })
    reservations = 2.times.map { ledger.reserve!(:cost, 0.1234) }

    expect(ledger.remaining(:cost)).to eq(0.7532)
    expect(BigDecimal.limit).to eq(2)
    expect { ledger.reserve!(:cost, 0.8) }.to raise_error(require_const("Smith::BudgetExceeded"))
    expect(BigDecimal.limit).to eq(2)

    reservations.each { ledger.release!(_1) }
    expect(ledger.remaining(:cost)).to eq(1.0)
    expect(BigDecimal.limit).to eq(2)
  ensure
    BigDecimal.limit(previous_limit)
  end

  it "keeps reservation receipts JSON-safe and detached from internal amounts" do
    ledger = ledger_class.new(limits: { cost: 0.3 })
    reservation = ledger.reserve!(:cost, 0.1)

    expect(reservation.amounts).to eq(cost: 0.1)
    expect(reservation.amounts.fetch(:cost)).to be_a(Float)
    expect(JSON.generate(reservation.amounts)).to eq('{"cost":0.1}')
  end

  it "rejects state changes whose public projection would become non-finite" do
    limit = 10**400
    ledger = ledger_class.new(limits: { cost: limit })

    expect { ledger.reserve!(:cost, 0.1) }.to raise_error(ArgumentError, /JSON-safe finite/)
    expect(ledger.remaining(:cost)).to eq(limit)
    expect(ledger.consumed).to eq({})
    expect(JSON.generate(ledger.remaining(:cost))).to eq(limit.to_s)
  end

  it "copies Hash and String subclasses through core ownership boundaries" do
    hostile_limits = Class.new(Hash) do
      def to_h
        { redirected: Class.new(Numeric).new }
      end
    end.new
    hostile_key = Class.new(String) do
      def dup
        "redirected"
      end
    end.new("tokens")
    hostile_limits.compare_by_identity
    hostile_limits[hostile_key] = 10

    ledger = ledger_class.new(limits: hostile_limits)
    hostile_key.replace("changed")

    expect(ledger.limits).to eq("tokens" => 10)
    expect(ledger.remaining("tokens")).to eq(10)
  end

  it "keeps decimal aggregation bounded across long-lived ledgers" do
    ledger = ledger_class.new(limits: { cost: 10.0 })
    amounts = [0.0001, 0.0002, 0.0003, 0.0004]
    reservations = 6_400.times.map { |index| ledger.reserve!(:cost, amounts.fetch(index % amounts.length)) }

    expect(ledger.remaining(:cost)).to be_finite
    reservations.each { ledger.release!(_1) }
    expect(ledger.remaining(:cost)).to eq(10.0)
  end

  it "fences reservations by identity and consumes them exactly once" do
    ledger = build_ledger(limit: 10)
    first = ledger.reserve!(:tokens, 5)
    second = ledger.reserve!(:tokens, 5)

    ledger.release!(first)
    expect(ledger.remaining(:tokens)).to eq(5)
    expect { ledger.release!(first) }.to raise_error(ArgumentError, /already settled/)

    ledger.reconcile!(second, 2)
    expect(ledger.consumed).to eq(tokens: 2)
    expect(ledger.remaining(:tokens)).to eq(8)
  end

  it "rejects reservation receipts issued by another ledger" do
    first = build_ledger(limit: 10)
    second = build_ledger(limit: 10)
    reservation = first.reserve!(:tokens, 5)

    expect { second.release!(reservation) }.to raise_error(ArgumentError, /another ledger/)
    expect(first.remaining(:tokens)).to eq(5)
    expect(second.remaining(:tokens)).to eq(10)
  end

  it "rejects custom and non-JSON-safe numeric values before mutation" do
    custom_number = Class.new(Numeric).new
    impersonator = Class.new(Numeric) do
      def is_a?(type)
        type == Integer || super
      end
    end.new
    ledger = ledger_class.new(limits: { tokens: 10 })

    expect { ledger.reserve!(:tokens, custom_number) }
      .to raise_error(ArgumentError, /Integer or Float/)
    expect { ledger.reserve!(:tokens, Rational(1, 2)) }
      .to raise_error(ArgumentError, /Integer or Float/)
    expect { ledger.reserve!(:tokens, impersonator) }
      .to raise_error(ArgumentError, /Integer or Float/)
    expect(ledger.remaining(:tokens)).to eq(10)
  end

  it "rolls back reservation publication when Thread#raise lands inside the protected swap" do
    entered = Queue.new
    registry_class = Class.new(Hash) do
      define_method(:initialize) { |queue| super().tap { @queue = queue } }
      define_method(:[]=) do |key, value|
        @queue << Thread.current
        sleep 0.05
        super(key, value)
      end
    end
    ledger = build_ledger(limit: 10)
    publication = ledger.instance_variable_get(:@publication)
    publication.instance_variable_set(:@reservations, registry_class.new(entered))
    errors = Queue.new
    worker = Thread.new do
      ledger.reserve!(:tokens, 10)
    rescue RuntimeError => e
      errors << e
    end

    entered.pop.raise("interrupt publication")
    worker.join

    expect(errors.pop.message).to eq("interrupt publication")
    expect(ledger.remaining(:tokens)).to eq(10)
  end

  it "rolls back settlement publication when Thread#raise lands inside the protected swap" do
    entered = Queue.new
    registry_class = Class.new(Hash) do
      define_method(:initialize) { |queue| super().tap { @queue = queue } }
      define_method(:delete) do |key|
        @queue << Thread.current
        sleep 0.05
        super(key)
      end
    end
    ledger = build_ledger(limit: 10)
    reservation = ledger.reserve!(:tokens, 10)
    publication = ledger.instance_variable_get(:@publication)
    registry = registry_class.new(entered)
    registry.merge!(publication.instance_variable_get(:@reservations))
    publication.instance_variable_set(:@reservations, registry)
    errors = Queue.new
    worker = Thread.new do
      ledger.reconcile!(reservation, 4)
    rescue RuntimeError => e
      errors << e
    end

    entered.pop.raise("interrupt settlement")
    worker.join

    expect(errors.pop.message).to eq("interrupt settlement")
    expect(ledger.consumed).to eq({})
    expect(ledger.remaining(:tokens)).to eq(0)
    ledger.reconcile!(reservation, 4)
    expect(ledger.consumed).to eq(tokens: 4)
  end

  it "keeps aggregate state and the receipt index consistent when Thread#kill lands during publication" do
    entered = Queue.new
    registry_class = Class.new(Hash) do
      define_method(:initialize) { |queue| super().tap { @queue = queue } }
      define_method(:[]=) do |key, value|
        @queue << Thread.current
        sleep 0.05
        super(key, value)
      end
    end
    ledger = build_ledger(limit: 10)
    publication = ledger.instance_variable_get(:@publication)
    publication.instance_variable_set(:@reservations, registry_class.new(entered))
    worker = Thread.new { ledger.reserve!(:tokens, 10) }

    entered.pop.kill
    worker.join

    reservations = publication.instance_variable_get(:@reservations)
    expect(ledger.remaining(:tokens)).to eq(0)
    expect(reservations.length).to eq(1)
  end

  it "rejects arithmetic that would make consumed state non-finite" do
    ledger = ledger_class.new(limits: { cost: Float::MAX })
    first = ledger.reserve!(:cost, 1.0)
    ledger.reconcile!(first, Float::MAX)
    second = ledger.reserve!(:cost, 0.0)

    expect { ledger.reconcile!(second, Float::MAX) }
      .to raise_error(ArgumentError, /JSON-safe finite/)
    expect(ledger.consumed).to eq(cost: Float::MAX)
  end

  it "rejects dimensions that were not declared in limits" do
    ledger = build_ledger(limit: 10)

    expect { ledger.reserve!(:cost, 1) }.to raise_error(ArgumentError, /unknown budget dimension/)
    expect { ledger.remaining(:cost) }.to raise_error(ArgumentError, /unknown budget dimension/)
    expect { ledger_class.new(limits: { tokens: 10 }, consumed: { cost: 1 }) }
      .to raise_error(ArgumentError, /unknown budget dimension/)
  end

  it "owns string dimensions and rejects mutable composite identifiers" do
    dimension = +"tokens"
    ledger = ledger_class.new(limits: { dimension => 10 })
    dimension.replace("changed")

    expect(ledger.remaining("tokens")).to eq(10)
    expect { ledger_class.new(limits: { [:tokens] => 10 }) }
      .to raise_error(ArgumentError, /dimension keys must be symbols or strings/)
  end
end
