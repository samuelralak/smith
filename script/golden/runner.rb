# frozen_string_literal: true

module CoreInvisibility
  # One scenario's surroundings: the local server answering as Anthropic,
  # the persistence adapter, and helpers for what a host does around a run.
  class Run
    attr_reader :server, :adapter

    def initialize(server)
      @server = server
      @adapter = Hosts::Adapter.new
    end

    def reply(**) = server.reply(**)

    # Runs a host call, keeping what it raised (a kill included).
    def capture
      yield
    rescue StandardError, Hosts::Killed => e
      CoreInvisibility.record.error(e)
      nil
    end

    def restore(klass, key) = klass.restore(key, adapter:)

    # A host call's answer worth keeping (a resume's or an expiry's).
    def note(label, value) = CoreInvisibility.record.add(:results, [label, value])

    # The run as it ended: its state, its usage entries and its result.
    def finish(workflow, result = nil)
      CoreInvisibility.record.state(workflow)
      CoreInvisibility.record.add(:usage_entries, workflow.usage_entries.map(&:to_h))
      CoreInvisibility.record.add(:results, result_facts(result)) if result
    end

    # Ends the run's wait as its deadline passes, as a host's scheduler does.
    def expire(klass, key)
      wait = restore(klass, key).awaiting
      deadline = wait.deadline_at
      deadline = Time.iso8601(deadline) if deadline.is_a?(String)
      Determinism.advance(deadline - Determinism.now)
      klass.expire_wait!(key, token: wait.token, now: Determinism.now, adapter:)
    end

    private

    def result_facts(result)
      { state: result.state, output: result.output, steps: result.steps.map { _1.slice(:transition, :from, :to) },
        last_error: result.last_error }
    end
  end

  # Runs every scenario in one mode and builds the document.
  class Runner
    # Measured on the monotonic clock: each reads its unit while it has the
    # type Smith gives it, so a type change still shows.
    TRANSIENT = { duration_ms: [Integer, "ms"], duration: [Float, "s"] }.freeze
    private_constant :TRANSIENT

    # The modes that run every scenario inside a trial, recorded by the
    # real recorder (slice 1a.4); the observer mode installs a test one.
    TRIALS = %w[trial concurrent credentialed].freeze

    def initialize(mode)
      @mode = mode
      @observer = Observer.new if mode == "observer"
      @recording = TRIALS.include?(mode)
      @observations = {}
      @server = SseServer.new
    end

    # Evals load (installing their recorder) before the host surface is
    # read, so a name they added to a host's classes would show.
    def call
      Smith::AttemptObservation.install(@observer) if @observer
      CoreInvisibility.prompted! if @mode == "prompted"
      require "smith/evals" if @recording
      surface = HostSurface.call
      selected = CoreInvisibility.scenarios.select { @mode != "concurrent" || _1.concurrent }
      scenarios = selected.to_h { [_1.name.to_s, run(_1)] }
      document(scenarios, surface)
    ensure
      @server.close
    end

    private

    def run(scenario)
      prepare
      run = Run.new(@server)
      @recorder = Recorded.recorder(scenario) if @recording
      within_trial { drive(scenario, run) }
      collect(scenario)
    end

    # A scenario the harness itself cannot go on with (a host call it relies
    # on is gone) stops there, recorded, so the others and the host surface
    # are still compared.
    def drive(scenario, run)
      scenario.drive.call(run)
    rescue StandardError => e
      CoreInvisibility.record.error(e)
    end

    def within_trial(&) = @recorder ? Recorded.within(@recorder, &) : yield

    def prepare
      Determinism.reset!
      CoreInvisibility.record = Record.new
      @requests_seen = @server.requests.length
      @server.answer
      configure(Smith.config)
      RubyLLM.configure { point_providers(_1) }
      CoreInvisibility.credentialed!(@server.url) if @mode == "credentialed"
      Smith.config.require_run_credentials = true if @mode == "fail_closed"
    end

    # Anthropic's and OpenAI's requests go to the local server.
    def point_providers(config)
      config.anthropic_api_key = "test"
      config.anthropic_api_base = @server.url
      config.openai_api_key = "test"
      config.openai_api_base = "#{@server.url}/v1"
      config.max_retries = 0
    end

    def configure(config)
      config.trace_adapter = Smith::Trace::Memory.new
      config.trace_content = true
      config.pricing = PRICES
      config.parallel_concurrency = @mode == "concurrent" ? 8 : 1
      config.response_memo = nil
      config.batch_queue = nil
      config.run_launcher = nil
      config.stream_sinks = {}
      config.artifact_store = Hosts::Artifacts.new
    end

    def collect(scenario)
      record = CoreInvisibility.record
      wire(record)
      Smith.config.trace_adapter.traces.each { record.add(:traces, trace(_1)) }
      record.add(:logs, %i[smith ruby_llm].zip(Hooks.drain_logs).to_h)
      observe(scenario)
      record.to_h(Determinism.draws)
    end

    # The requests the server took, and the replies a scenario queued and
    # never used, dropped before the next.
    def wire(record)
      @server.requests.drop(@requests_seen).each { record.add(:requests, request(_1)) }
      record.add(:results, { unused_replies: @server.pending_replies })
      @server.clear_replies
    end

    # The test observer's summaries, or the recorder's step records.
    def observe(scenario)
      @observations[scenario.name.to_s] = @observer.drain.map { Observer.summary(_1) } if @observer
      @observations[scenario.name.to_s] = @recorder.steps if @recorder
    end

    # The server's port changes from run to run; it reads PORT.
    def request(request)
      port = @server.url.delete_prefix("http://")
      headers = request.headers.except("user-agent").transform_values { _1.gsub(port, "127.0.0.1:PORT") }
      [request.verb, request.path, headers, request.raw.to_s]
    end

    def trace(entry)
      data = entry[:data].to_h do |key, value|
        type, unit = TRANSIENT[key]
        [key, type && value.is_a?(type) ? unit : value]
      end
      { type: entry[:type], data: }
    end

    def document(scenarios, surface)
      doc = { "format" => FORMAT, "smith" => Environment.smith, "environment" => Environment.versions,
              "process" => Environment.process, "host_surface" => surface, "scenarios" => scenarios }
      doc["observations"] = @observations if @observer || @recording
      doc["prompts_declared"] = Smith::Prompts.__send__(:declared?) if @mode == "prompted"
      doc
    end
  end
end
