# frozen_string_literal: true

# A host that settles a charge itself (a batch result no run took, say)
# prices the usage it read with Smith::Budget::HostLedger.amount, as Smith
# prices its own. Its usage is any object, a BasicObject included, answering
# input_tokens, output_tokens, cache_read_tokens and cache_write_tokens, all
# that was asked of it up to 0.15.0. It carries an image count when its own
# respond_to? says so, or, with none of its own, when Kernel#respond_to? sees
# it publicly; otherwise it has no images.
RSpec.describe "Smith::Budget::HostLedger.amount" do
  let(:host_ledger) { require_const("Smith::Budget::HostLedger") }
  let(:counts) { { input_tokens: 1200, output_tokens: 340, cache_read_tokens: 5000, cache_write_tokens: 800 } }
  let(:images) { { image_input_tokens: 1000, image_output_tokens: 300 } }
  let(:with_images) { Struct.new(*counts.keys, :image_input_tokens, :image_output_tokens) }
  let(:image_cost) { (1000 * (0.00001 - 0.000003)) + (300 * (0.00004 - 0.000015)) }

  around do |example|
    saved = Smith.config.pricing
    # Image rates are set, so an image count read where there is none would show in the cost.
    Smith.config.pricing = Smith::Pricing.validate_catalog!(
      %w[anthropic claude-sonnet-5-5] => {
        input_cost_per_token: 0.000003, output_cost_per_token: 0.000015,
        cache_read_cost_per_token: 0.0000003, cache_write_cost_per_token: 0.00000375,
        image_input_cost_per_token: 0.00001, image_output_cost_per_token: 0.00004, batch_discount: 0.5
      }
    )
    example.run
  ensure
    Smith.config.pricing = saved
  end

  def priced(usage, mode: :batch)
    amount = host_ledger.amount(usage, model: "claude-sonnet-5-5", provider: "anthropic", mode:)
    [amount.input_tokens, amount.output_tokens, amount.tokens, amount.cost]
  end

  # A usage with only these readers: no respond_to?, public_send or anything else of Object's.
  def self.basic_usage(readers)
    Class.new(BasicObject) { readers.each { |name, value| define_method(name) { value } } }.new
  end

  # The usages below answer through method_missing and say so only through a respond_to? of their own,
  # with no respond_to_missing?, which Ruby's convention asks for and they predate.
  # rubocop:disable Style/MissingRespondToMissing

  # Minitest::Mock's shape (minitest 6 ships it apart, as minitest-mock, which this bundle lacks): it
  # undefines Object's methods but its own and answers what it expects.
  def self.mock_shaped(expected)
    Class.new do
      alias_method :__respond_to?, :respond_to?
      instance_methods.each { |name| undef_method(name) unless name.start_with?("__") || name == :object_id }
      define_method(:initialize) { |values| @expected = values }
      def respond_to?(name, *) = @expected.key?(name) || __respond_to?(name, *)
      def method_missing(name, *) = @expected.key?(name) ? @expected.fetch(name) : super
    end.new(expected)
  end

  # A class of its time that overrides respond_to? for what it answers.
  def self.says_so(values)
    Class.new do
      define_method(:initialize) { |given| @values = given }
      def respond_to?(name, *) = @values.key?(name) || super
      def method_missing(name, *) = @values.key?(name) ? @values[name] : super
    end.new(values)
  end

  # A forwarding proxy that forwards respond_to? as well as the calls.
  def self.forwarding(target)
    Class.new do
      define_method(:initialize) { |given| @target = given }
      def respond_to?(name, *) = @target.respond_to?(name, *) || super
      def method_missing(name, *args, &) = @target.respond_to?(name) ? @target.public_send(name, *args, &) : super
    end.new(target)
  end

  # A BasicObject that forwards every call, respond_to? included, through method_missing alone, so
  # Ruby sees no respond_to? of its own.
  def self.basic_forwarding(target)
    Class.new(BasicObject) do
      define_method(:initialize) { |given| @target = given }
      def method_missing(name, *args, &) = @target.__send__(name, *args, &)
    end.new(target)
  end
  # rubocop:enable Style/MissingRespondToMissing

  {
    "a Data" => ->(counts) { Data.define(*counts.keys).new(**counts) },
    "a Struct" => ->(counts) { Struct.new(*counts.keys).new(*counts.values) },
    "a plain object" => lambda { |counts|
      Object.new.tap { |usage| counts.each { |name, value| usage.define_singleton_method(name) { value } } }
    },
    "a BasicObject" => ->(counts) { basic_usage(counts) },
    "a RubyLLM::Message" => lambda { |counts|
      RubyLLM::Message.new(role: :assistant, content: "ok", input_tokens: counts[:input_tokens],
                           output_tokens: counts[:output_tokens], cached_tokens: counts[:cache_read_tokens],
                           cache_creation_tokens: counts[:cache_write_tokens])
    }
  }.each do |kind, build|
    it "prices a host's usage, #{kind} answering only the four counts, as 0.15.0 did, with no images" do
      usage = build.call(counts)

      # The amounts the released 0.15.0 gem gives for these same calls.
      expect(priced(usage)).to eq([7000, 340, 7340, 0.0066])
      expect(priced(usage, mode: :sync)).to eq([7000, 340, 7340, 0.0132])
    end
  end

  {
    "a Struct" => ->(readers) { Struct.new(*readers.keys).new(**readers) },
    "Smith's own ProviderUsage" => ->(readers) { Smith::Agent::ProviderUsage.new(**readers) },
    "a BasicObject" => ->(readers) { basic_usage(readers) }
  }.each do |kind, build|
    it "prices the image counts #{kind} carries at the catalog's image rates" do
      usage = build.call(counts.merge(images))

      expect(priced(usage).first(3)).to eq([7000, 340, 7340])
      expect(priced(usage).last).to be_within(1e-12).of(0.0066 + (image_cost * 0.5))
      expect(priced(usage, mode: :sync).last).to be_within(1e-12).of(0.0132 + image_cost)
    end
  end

  {
    "a Minitest::Mock-shaped usage" => ->(readers) { mock_shaped(readers) },
    "a class overriding respond_to?" => ->(readers) { says_so(readers) },
    "a forwarding proxy that forwards respond_to?" => lambda { |readers|
      forwarding(Struct.new(*readers.keys).new(**readers))
    }
  }.each do |kind, build|
    it "asks #{kind} its own respond_to?, pricing image counts as 0.16.0 did and four counts as 0.15.0 did" do
      expect(priced(build.call(counts.merge(images))).last).to be_within(1e-12).of(0.0066 + (image_cost * 0.5))
      expect(priced(build.call(counts))).to eq([7000, 340, 7340, 0.0066])
    end
  end

  it "prices a forwarding BasicObject with no respond_to? or respond_to_missing? of its own as Ruby sees it" do
    four = self.class.basic_forwarding(Struct.new(*counts.keys).new(**counts))
    six = self.class.basic_forwarding(with_images.new(**counts, **images))

    # Ruby sees no respond_to? on it, so Kernel's is asked, which sees no image count: 0.15.0's amount either way.
    expect(priced(four)).to eq([7000, 340, 7340, 0.0066])
    expect(priced(six)).to eq([7000, 340, 7340, 0.0066])
  end

  it "prices the one image count a usage answers when it answers only one" do
    output_only = Data.define(*counts.keys, :image_output_tokens).new(**counts, image_output_tokens: 300)
    input_only = Data.define(*counts.keys, :image_input_tokens).new(**counts, image_input_tokens: 1000)

    expect(priced(output_only).last).to be_within(1e-12).of(0.0066 + (300 * (0.00004 - 0.000015) * 0.5))
    expect(priced(input_only).last).to be_within(1e-12).of(0.0066 + (1000 * (0.00001 - 0.000003) * 0.5))
  end

  it "counts only the image counts a usage answers publicly, never calling a private one" do
    hidden = Class.new(with_images) { private :image_input_tokens, :image_output_tokens }

    expect(priced(hidden.new(**counts, **images))).to eq([7000, 340, 7340, 0.0066])
  end

  it "reads an image count that is nil, negative or not an Integer as none" do
    [[nil, nil], [-5, "300"], [1.5, nil]].each do |image_input, image_output|
      usage = with_images.new(**counts, image_input_tokens: image_input, image_output_tokens: image_output)

      expect(priced(usage)).to eq([7000, 340, 7340, 0.0066])
    end
  end
end
