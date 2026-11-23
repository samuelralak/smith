# frozen_string_literal: true

require "open3"

# A lock Smith shares across a process is made once, so threads that first
# use what it guards together share it. Each example runs in a fresh process,
# at first use, and holds the first thread to make a lock at `site` until a
# second one does, so a lock made on first use is made twice.
RSpec.describe "Smith's shared locks at first use" do
  def first_use(lock_class, site, body)
    script = <<~RUBY
      require "smith"
      arrivals = Queue.new
      gate = Queue.new
      #{lock_class}.singleton_class.prepend(Module.new do
        define_method(:new) do |*args|
          if caller_locations(1, 1).first.path.end_with?(#{site.inspect})
            arrivals << true
            arrivals.size == 1 ? gate.pop(timeout: 2) : gate << true
          end
          super(*args)
        end
      end)
      waited = ->(&done) { deadline = Time.now + 2; Thread.pass until done.call || Time.now > deadline }
      #{body}
    RUBY
    stdout, stderr, status = Open3.capture3(RbConfig.ruby, "-I", File.expand_path("../../lib", __dir__), "-e", script)
    expect([status.success?, stderr]).to eq([true, ""])
    stdout
  end

  it "builds the artifact store once for threads that first resolve it together, and gives each that store" do
    out = first_use("Mutex", "smith/artifacts.rb", <<~RUBY)
      built = Queue.new
      threads = []
      Smith.config.artifact_store = Class.new(Smith::Artifacts::Memory) do
        define_method(:initialize) do |**options|
          built << self
          waited.call { built.size >= 2 || (threads.size == 2 && (threads - [Thread.current]).all?(&:stop?)) }
          super(**options)
        end
      end
      threads << Thread.new { Smith.artifact_backend }
      waited.call { arrivals.size >= 1 || built.size >= 1 }
      threads << Thread.new { Smith.artifact_backend }
      answers = [*threads.map(&:value), Smith.artifact_backend]
      p [built.size, answers.map(&:object_id).uniq.size]
    RUBY

    expect(out).to eq("[1, 1]\n")
  end

  it "builds the persistence adapter once for threads that first ask together, and gives each that adapter" do
    out = first_use("Mutex", "lib/smith.rb", <<~RUBY)
      built = Queue.new
      threads = []
      adapter = Class.new(Smith::PersistenceAdapters::Memory) do
        define_method(:initialize) do
          built << self
          waited.call { built.size >= 2 || (threads.size == 2 && (threads - [Thread.current]).all?(&:stop?)) }
          super()
        end
      end
      Smith.configure { |config| config.persistence_adapter = adapter }
      threads << Thread.new { Smith.persistence_adapter }
      waited.call { arrivals.size >= 1 || built.size >= 1 }
      threads << Thread.new { Smith.persistence_adapter }
      answers = [*threads.map(&:value), Smith.persistence_adapter]
      p [built.size, answers.map(&:object_id).uniq.size]
    RUBY

    expect(out).to eq("[1, 1]\n")
  end

  it "holds threads that first use the agent registry together to one lock" do
    out = first_use("Monitor", "smith/agent/registry.rb", <<~RUBY)
      first_in = Queue.new
      second_in = Queue.new
      release = Queue.new
      registry = Smith::Agent::Registry
      holder = Thread.new { registry.registry_monitor.synchronize { first_in << true; release.pop } }
      waited.call { arrivals.size >= 1 || first_in.size >= 1 }
      second = Thread.new { registry.registry_monitor.synchronize { second_in << true } }
      waited.call { first_in.size == 1 && (second_in.size == 1 || second.stop?) }
      at_once = first_in.size + second_in.size
      release << true
      [holder, second].each(&:join)
      p at_once
    RUBY

    expect(out).to eq("1\n")
  end

  # A store or adapter whose construction asks Smith for itself would wait on
  # the lock its own thread holds; Smith says what happened instead.
  it "refuses an artifact store or a persistence adapter whose construction asks Smith for itself" do
    saved = %i[artifact_store persistence_adapter persistence_options].to_h { [_1, Smith.config.public_send(_1)] }
    Smith.config.artifact_store = Class.new(Smith::Artifacts::Memory) do
      def initialize(**)
        Smith.artifact_backend
        super
      end
    end
    Smith.configure do |config|
      config.persistence_adapter = Class.new(Smith::PersistenceAdapters::Memory) do
        def initialize
          Smith.persistence_adapter
          super
        end
      end
      config.persistence_options = {}
    end

    expect { Smith.artifact_backend }
      .to raise_error(Smith::Error, "the artifact store's construction asked Smith for the artifact store, " \
                                    "which it was still building")
    expect { Smith.persistence_adapter }
      .to raise_error(Smith::Error, "the persistence adapter's construction asked Smith for the persistence " \
                                    "adapter, which it was still building")
  ensure
    Smith.configure { |config| saved.each { |name, value| config.public_send(:"#{name}=", value) } }
  end
end
