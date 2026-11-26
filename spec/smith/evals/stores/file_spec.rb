# frozen_string_literal: true

require "fileutils"
require "json"
require "open3"
require "tmpdir"
require "smith/evals"

# The file store (slice-1a design, 9.2 to 9.4): the store example group, then
# what only files have. Writes are atomic and durable, a crash leaves whole
# records or a torn last line readers skip, leases are flocks the operating
# system frees when a process dies and a forked child never holds, and no
# path leaves the root. Crashes are real: a child process is killed with
# SIGKILL in the middle of a write.
RSpec.describe Smith::Evals::Stores::File do
  around do |example|
    Dir.mktmpdir("smith-file-store") do |dir|
      @dir = dir
      example.run
    end
  end

  let(:root) { File.join(@dir, "store") }
  let(:store) { described_class.new(root:, clock: -> { EvalRecords::CLOCK_AT }) }
  let(:other_store) { described_class.new(root: File.join(@dir, "other")) }
  let(:scope) { EvalRecords.scope }
  let(:run_id) { EvalRecords.eval_run_id }
  let(:scope_dir) { File.join(root, "v1", "scopes", Smith::Scope.digest(scope)) }
  let(:run_dir) { File.join(scope_dir, "runs", run_id) }
  # The folders above a run's, each flushed with it on a create and a lease.
  let(:above) do
    [root, File.join(root, "v1"), File.join(root, "v1", "scopes"), scope_dir, File.join(scope_dir, "runs")]
  end
  # How a write is flushed to the drive: F_FULLFSYNC on macOS, fsync elsewhere.
  let(:full) { RUBY_PLATFORM.include?("darwin") ? :full : :sync }

  it_behaves_like "an eval store"
  it_behaves_like "a tuning store"

  def store_with(clock:) = described_class.new(root: File.join(@dir, "clocked"), clock:)

  # Each child loads Smith and opens a store on the parent's root; RECORDS is
  # the contract record its lines are made from, so they stay schema-valid.
  def preamble
    <<~RUBY
      require "json"
      require "smith/evals"
      $stdout.sync = true
      ROOT, RECORDS = ARGV.shift(2)
      STORE = Smith::Evals::Stores::File.new(root: ROOT)
      HEADER = JSON.parse(File.read(File.join(RECORDS, "header.json")))
      SCOPE = HEADER.fetch("scope")
      RUN = HEADER.fetch("eval_run_id")
      TEMPLATE = JSON.parse(File.foreach(File.join(RECORDS, "trials.jsonl")).first)
      def line(number, output: nil, run: RUN)
        TEMPLATE.merge("eval_run_id" => run, "trial_id" => format("tr_%032x", number), "output" => output)
      end
    RUBY
  end

  def command(script, *args)
    [RbConfig.ruby, "-I", File.expand_path("../../../../lib", __dir__), "-e", preamble + script, root,
     EvalRecords::RUN, *args]
  end

  def child(script, *args, &) = Open3.popen2(*command(script, *args), &)

  def json(value) = EvalRecords.json(value)
  def created! = store.create_record(scope:, header: EvalRecords.header)
  def trials = store.each_trial(scope:, eval_run_id: run_id).to_a
  def path(name) = File.join(run_dir, name)

  def leased = store.acquire_lease(scope:, eval_run_id: run_id)
  def append(lease, line) = store.append_trial(scope:, eval_run_id: run_id, line:, lease:)
  def temporary(name, folder = path("tmp")) = %r{\A#{Regexp.escape(folder)}/#{name}\.[0-9a-f]{16}\.jsonl?\z}

  # Every flush and rename from here on, in order: a flush is a path and
  # :full (F_FULLFSYNC) or :sync (fsync); a rename is [:rename, from, to].
  def flushes
    seen = []
    { fsync: :sync, fcntl: :full }.each { |name, kind| flushed(seen, name, kind) }
    allow(File).to receive(:rename).and_wrap_original do |original, *names|
      seen << [:rename, *names]
      original.call(*names)
    end
    seen
  end

  def flushed(seen, name, kind)
    allow_any_instance_of(File).to receive(name).and_wrap_original do |original, *args|
      seen << [original.receiver.path, kind] if kind == :sync || args.first == 51
      original.call(*args)
    end
  end

  def finished(waiter, seconds = 60)
    done = waiter.join(seconds)
    Process.kill("KILL", waiter.pid) unless done
    expect(done).not_to be_nil, "the child blocked"
  end

  def killed(waiter)
    Process.kill("KILL", waiter.pid)
    expect(waiter.value.termsig).to eq(Signal.list.fetch("KILL"))
  end

  describe "its layout" do
    it "keeps the v1 layout, a run's folder the published example's, byte for byte" do
      created!
      lease = store.acquire_lease(scope:, eval_run_id: run_id)
      EvalRecords.segments.each { store.append_segment(scope:, eval_run_id: run_id, segment: _1, lease:) }
      EvalRecords.trials.each { store.append_trial(scope:, eval_run_id: run_id, line: _1, lease:) }
      [EvalRecords.first_summary, EvalRecords.summary].each do |summary|
        store.write_summary(scope:, eval_run_id: run_id, summary:, lease:)
      end
      store.request_cancel(scope:, eval_run_id: run_id, actor: Smith::Evals::Actor.person("usr_51a8"), reason: nil)
      lease.release

      expect(Dir.children(root)).to eq(["v1"])
      expect(Dir.children(File.join(root, "v1", "scopes"))).to eq([Smith::Scope.digest(scope)])
      expect(Dir.children(scope_dir).sort).to eq(%w[runs scope.json])
      expect(File.read(File.join(scope_dir, "scope.json")))
        .to eq("#{JSON.pretty_generate(Smith::Scope.build(scope))}\n")
      expect(Dir.children(run_dir).sort)
        .to eq(%w[cancel.json header.json lease segments.jsonl summary.json tmp trials.jsonl])
      expect(Dir.children(path("tmp"))).to eq([])
      EvalRecords::FILES.each { expect(File.binread(path(_1))).to eq(EvalRecords.text(_1).b), _1 }
      reopened = described_class.new(root:)
      expect(json(reopened.read_summary(scope:, eval_run_id: run_id))).to eq(json(EvalRecords.summary))
    end

    it "creates nothing until its first write, and holds its root as an absolute path from the start" do
      Dir.chdir(@dir) do
        relative = described_class.new(root: "relative/store")
        relative.read_header(scope:, eval_run_id: run_id)
        relative.list_records(scope:)

        expect(relative.root).to eq(File.join(Dir.pwd, "relative", "store"))
        expect(Dir.children(@dir)).to eq([])
      end
    end

    it "ignores what it does not know in a scope's runs, and a run folder with no header yet" do
      created!
      FileUtils.mkdir_p(File.join(scope_dir, "runs", "er_unknown"))
      FileUtils.mkdir_p(File.join(scope_dir, "runs", EvalRecords.run_id(5)))
      File.write(File.join(scope_dir, "runs", "notes.txt"), "kept by hand")
      File.write(path("notes.txt"), "kept by hand")

      expect(store.list_records(scope:)["records"].map { _1["eval_run_id"] }).to eq([run_id])
      expect(store.read_header(scope:, eval_run_id: EvalRecords.run_id(5))).to be_nil
    end

    # EPERM may also be a protected folder or an immutable flag.
    it "says why the first create cannot link: no hard links, or a folder or file it may not change" do
      eperm = "#{scope_dir.delete_prefix("#{root}/")}/scope.json cannot be linked (Errno::EPERM): the file store " \
              "needs a local file system with hard links, and folders and files it may change"
      { Errno::EOPNOTSUPP => "the file store needs a local file system with hard links",
        Errno::EPERM => eperm }.each do |error, message|
        FileUtils.rm_rf(root)
        allow(File).to receive(:link).and_raise(error)

        expect { created! }.to raise_error(Smith::Evals::StoreError, message) { |raised|
          expect(raised.operation).to eq(:create_record)
        }
        expect(Dir.children(path("tmp"))).to eq([])
      end
    end

    it "works under a root that is itself a link, as macOS's /tmp is" do
      real = File.join(@dir, "real").tap { FileUtils.mkdir_p(_1) }
      linked = File.join(@dir, "linked").tap { File.symlink(real, _1) }
      linked_store = described_class.new(root: linked)

      expect(linked_store.create_record(scope:, header: EvalRecords.header)).to eq(:created)
      lease = linked_store.acquire_lease(scope:, eval_run_id: run_id)
      expect(linked_store.append_trial(scope:, eval_run_id: run_id, line: EvalRecords.trials.first, lease:))
        .to eq(:appended)
      lease.release
      expect(linked_store.list_records(scope:)["records"].size).to eq(1)
      expect(Dir.children(real)).to eq(["v1"])
    end

    it "keeps what it writes to its owner: folders 0700 and files 0600" do
      mask = File.umask(0o022)
      created!
      lease = leased
      store.append_segment(scope:, eval_run_id: run_id, segment: EvalRecords.segments.first, lease:)
      append(lease, EvalRecords.trials.first)
      store.write_summary(scope:, eval_run_id: run_id, summary: EvalRecords.first_summary, lease:)
      store.request_cancel(scope:, eval_run_id: run_id, actor: Smith::Evals::Actor.person("usr_1"), reason: nil)
      lease.release
      File.open(path("trials.jsonl"), "ab") { _1.write("{") }
      leased.release
      written = [root, *Dir.glob("**/*", base: root).map { File.join(root, _1) }]
      folders, files = written.partition { File.directory?(_1) }

      expect(folders.size).to eq(7)
      expect(folders.map { File.stat(_1).mode & 0o777 }.uniq).to eq([0o700])
      expect(files.map { File.stat(_1).mode & 0o777 }.uniq).to eq([0o600])
    ensure
      File.umask(mask) if mask
    end

    it "refuses a scope folder that names another scope" do
      created!
      File.write(File.join(scope_dir, "scope.json"), JSON.generate("tenant" => "someone-else"))

      expect { store.create_record(scope:, header: EvalRecords.header_for(EvalRecords.run_id(2))) }
        .to raise_error(Smith::Evals::StoreError, /scope.json/)
    end
  end

  describe "durability" do
    # Each name a write adds is flushed in its folder, and every folder from
    # the root down to the run's on each create and each lease, so a name a
    # killed writer never flushed is flushed by the next.
    it "flushes every folder from the root down to the run's on each create" do
      seen = flushes
      created!
      expect(seen).to match([*above.map { [_1, full] }, [run_dir, full],
                             [temporary("scope"), full], [scope_dir, full], [temporary("header"), full],
                             [run_dir, full]])
      other = File.join(scope_dir, "runs", EvalRecords.run_id(2))
      seen.clear
      store.create_record(scope:, header: EvalRecords.header_for(EvalRecords.run_id(2)))
      expect(seen).to match([*above.map { [_1, full] }, [other, full],
                             [temporary("header", File.join(other, "tmp")), full], [other, full]])
    end

    it "flushes each record to the drive before it returns, and the folder when a name is added" do
      created!
      seen = flushes
      lease = leased
      expect(seen).to eq([*above.map { [_1, full] }, [run_dir, full]])
      seen.clear
      2.times { append(lease, EvalRecords.trial_for(run_id, _1)) }
      expect(seen).to eq([[path("trials.jsonl"), full], [run_dir, full], [path("trials.jsonl"), full]])
      seen.clear
      store.write_summary(scope:, eval_run_id: run_id, summary: EvalRecords.first_summary, lease:)
      expect(seen).to match([[temporary("summary"), full], [:rename, temporary("summary"), path("summary.json")],
                             [run_dir, full]])
      seen.clear
      store.request_cancel(scope:, eval_run_id: run_id, actor: Smith::Evals::Actor.person("usr_1"), reason: nil)
      expect(seen).to match([[temporary("cancel"), full], [run_dir, full]])
    end

    it "flushes a cut's copy before renaming it over the line file, then its folders" do
      created!
      lease = leased
      append(lease, EvalRecords.trials.first)
      lease.release
      File.open(path("trials.jsonl"), "ab") { _1.write('{"torn') }
      seen = flushes
      leased

      expect(seen).to match([[temporary("trials"), full], [:rename, temporary("trials"), path("trials.jsonl")],
                             [run_dir, full], *above.map { [_1, full] }, [run_dir, full]])
    end

    it "falls back to fsync where the file system has no full flush" do
      created!
      synced = []
      allow_any_instance_of(File).to receive(:fcntl).and_raise(Errno::ENOTSUP)
      allow_any_instance_of(File).to receive(:fsync).and_wrap_original do |original, *args|
        synced << original.receiver.path
        original.call(*args)
      end

      expect(append(leased, EvalRecords.trials.first)).to eq(:appended)
      expect(synced).to include(path("trials.jsonl"), run_dir)
    end

    it "removes a stray temporary older than an hour on the next create, and keeps a younger one" do
      created!
      old = path("tmp/header.#{"a" * 16}.json")
      young = path("tmp/summary.#{"b" * 16}.json")
      [old, young].each { File.write(_1, "{") }
      File.utime(Time.now - 3601, Time.now - 3601, old)
      File.utime(Time.now - 600, Time.now - 600, young)

      expect(created!).to eq(:exists)
      expect(Dir.children(path("tmp"))).to eq([File.basename(young)])
    end

    # Times on a local file system are the system clock's, so a store whose
    # own clock runs ahead (a test's, say) never sweeps a write in flight.
    it "ages temporaries by the system clock, so a store whose clock runs ahead keeps a young one" do
      created!
      young = path("tmp/header.#{"c" * 16}.json").tap { File.write(_1, "{") }
      ahead = described_class.new(root:, clock: -> { Time.now + 7200 })

      expect(ahead.create_record(scope:, header: EvalRecords.header)).to eq(:exists)
      ahead.acquire_lease(scope:, eval_run_id: run_id).release
      expect(Dir.children(path("tmp"))).to eq([File.basename(young)])
    end

    # A copy a holder killed mid-cut left is swept by a later lease too.
    it "removes, as the next lease holder, a stray temporary older than an hour, as a create does" do
      created!
      old = %w[summary.json trials.jsonl segments.jsonl].map { path("tmp/#{_1.sub(".", ".#{"d" * 16}.")}") }
      young = path("tmp/trials.#{"e" * 16}.jsonl")
      [*old, young].each { File.write(_1, "{") }
      old.each { File.utime(Time.now - 3601, Time.now - 3601, _1) }
      leased.release

      expect(Dir.children(path("tmp"))).to eq([File.basename(young)])
    end

    # A tmp folder removed by hand: a lease needs none to sweep, and makes it
    # again when a cut needs a temporary.
    it "leases a run whose tmp folder is gone, making the folder again when a cut needs it" do
      created!
      lease = leased
      append(lease, EvalRecords.trials.first)
      lease.release
      FileUtils.rm_rf(path("tmp"))
      leased.release
      File.open(path("trials.jsonl"), "ab") { _1.write('{"torn') }
      FileUtils.rm_rf(path("tmp"))
      lease = leased

      expect(File.binread(path("trials.jsonl"))).to eq("#{json(EvalRecords.trials.first)}\n".b)
      expect(store.write_summary(scope:, eval_run_id: run_id, summary: EvalRecords.first_summary, lease:))
        .to eq(:written)
      expect(Dir.children(path("tmp"))).to eq([])
    end

    it "sweeps only temporaries of its own form" do
      created!
      others = %w[notes.txt header.json summary.12.json trials.ABCDEF0123456789.jsonl]
      long_ago = Time.now - 7200
      others.each do |name|
        File.write(path("tmp/#{name}"), "x")
        File.utime(long_ago, long_ago, path("tmp/#{name}"))
      end
      created!
      leased.release

      expect(Dir.children(path("tmp")).sort).to eq(others.sort)
    end
  end

  describe "a crash in the middle of a write" do
    # The child writes, then stops in the middle of the next write (half a
    # line on disk, or a temporary not yet linked or renamed) and says
    # "torn"; the parent kills it with SIGKILL and reads what is left.
    def torn_script
      <<~RUBY
        STORE.create_record(scope: SCOPE, header: HEADER)
        lease = STORE.acquire_lease(scope: SCOPE, eval_run_id: RUN)
        # $stdout and Kernel by name: inside a File method, puts writes to the file.
        halt = Module.new { def halt = $stdout.puts("torn") || Kernel.sleep }
        case ARGV.first
        when "append"
          2.times { STORE.append_trial(scope: SCOPE, eval_run_id: RUN, line: line(_1, output: "x" * 50_000), lease:) }
          File.prepend(halt, Module.new do
            def syswrite(data) = path.end_with?(".jsonl") ? super(data.byteslice(0, data.bytesize / 2)) && halt : super
            def write(*data) = path.end_with?(".jsonl") ? super(data.join.byteslice(0, 100_000)) && halt : super
          end)
          STORE.append_trial(scope: SCOPE, eval_run_id: RUN, line: line(2, output: "y" * 400_000), lease:)
        when "create"
          File.singleton_class.prepend(halt, Module.new { def link(*) = halt })
          STORE.create_record(scope: SCOPE, header: HEADER.merge("eval_run_id" => format("er_%032x", 2)))
        when "cancel"
          File.singleton_class.prepend(halt, Module.new { def link(*) = halt })
          STORE.request_cancel(scope: SCOPE, eval_run_id: RUN, actor: { "kind" => "person", "id" => "p" }, reason: nil)
        when "summary"
          summary = JSON.parse(File.read(ARGV[1]))
          STORE.write_summary(scope: SCOPE, eval_run_id: RUN, summary:, lease:)
          File.singleton_class.prepend(halt, Module.new { def rename(*) = halt })
          STORE.write_summary(scope: SCOPE, eval_run_id: RUN, summary: summary.merge("summary_revision" => 2), lease:)
        end
      RUBY
    end

    def torn(mode)
      summary = File.join(@dir, "summary.json").tap { File.write(_1, JSON.generate(EvalRecords.first_summary)) }
      child(torn_script, mode, summary) do |input, output, waiter|
        expect(output.gets).to eq("torn\n")
        killed(waiter)
        input.close
      end
    end

    it "leaves a torn last line mid-append, which readers skip and the next lease holder cuts" do
      torn("append")
      whole = 2.times.map do |number|
        EvalRecords.trials.first.merge("eval_run_id" => run_id, "trial_id" => EvalRecords.trial_id(number),
                                       "output" => "x" * 50_000)
      end

      expect(File.binread(path("trials.jsonl"))).not_to end_with("\n")
      expect(trials.map { json(_1) }).to eq(whole.map { json(_1) })
      lease = store.acquire_lease(scope:, eval_run_id: run_id)
      expect(File.binread(path("trials.jsonl"))).to eq(whole.map { "#{json(_1)}\n" }.join.b)
      store.append_trial(scope:, eval_run_id: run_id, line: EvalRecords.trial_for(run_id, 7), lease:)
      expect(trials.size).to eq(3)
      expect(Dir.children(path("tmp"))).to eq([])
    end

    it "leaves no header, only a stray temporary, mid-create; the next create of the run succeeds" do
      torn("create")
      other = EvalRecords.run_id(2)
      stray = File.join(scope_dir, "runs", other, "tmp")

      expect(store.read_header(scope:, eval_run_id: other)).to be_nil
      expect(store.list_records(scope:)["records"].map { _1["eval_run_id"] }).to eq([run_id])
      expect(Dir.children(stray)).to match([/\Aheader\.[0-9a-f]+\.json\z/])
      File.utime(Time.now - 7200, Time.now - 7200, File.join(stray, Dir.children(stray).first))
      expect(store.create_record(scope:, header: EvalRecords.header_for(other))).to eq(:created)
      expect(Dir.children(stray)).to eq([])
    end

    it "keeps the old summary whole mid-replace, and sets no flag mid-cancel" do
      torn("summary")
      expect(json(store.read_summary(scope:, eval_run_id: run_id))).to eq(json(EvalRecords.first_summary))

      FileUtils.rm_rf(root)
      torn("cancel")
      expect(store.cancel_request(scope:, eval_run_id: run_id)).to be_nil
      expect(store.request_cancel(scope:, eval_run_id: run_id, actor: Smith::Evals::Actor.person("usr_1"),
                                  reason: nil)).to eq(:requested)
    end

    it "never leaves a partial record readable when a busy writer is killed at any moment" do
      script = <<~RUBY
        random = Random.new(Integer(ARGV.first))
        (1..).each do |number|
          run = format("er_%032x", number)
          STORE.create_record(scope: SCOPE, header: HEADER.merge("eval_run_id" => run))
          lease = STORE.acquire_lease(scope: SCOPE, eval_run_id: run)
          12.times do |index|
            output = "z" * random.rand(1..300_000)
            STORE.append_trial(scope: SCOPE, eval_run_id: run, line: line(index, output:, run:), lease:)
          end
          puts run
          lease.release
        end
      RUBY
      random = Random.new(4242)
      3.times do |round|
        child(script, round.to_s) do |input, output, waiter|
          output.gets
          sleep(random.rand(0.05..0.4))
          killed(waiter)
          input.close
        end

        store.list_records(scope:, limit: 1000)["records"].map { _1["eval_run_id"] }.each do |id|
          lines = store.each_trial(scope:, eval_run_id: id).map { _1["trial_id"] }
          expect(lines).to eq(lines.size.times.map { EvalRecords.trial_id(_1) })
          store.acquire_lease(scope:, eval_run_id: id).release
          file = File.join(scope_dir, "runs", id, "trials.jsonl")
          expect(File.exist?(file) ? File.binread(file) : "").to match(/\A\z|\n\z/)
        end
        FileUtils.rm_rf(root)
      end
    end
  end

  # Slice 5a: a tuning run's folder sits beside the scope's eval runs, read
  # as its records are, its lines cut and swept as a run's are.
  describe "a tuning run" do
    let(:tuning_id) { TuningRecords.tuning_run_id }
    let(:tuning_scope) { TuningRecords.scope }
    let(:tuning_dir) { File.join(root, "v1", "scopes", Smith::Scope.digest(tuning_scope), "tuning", tuning_id) }
    let(:tuning_lease) { store.acquire_lease(scope: tuning_scope, tuning_run_id: tuning_id) }

    before { store.create_tuning(scope: tuning_scope, header: TuningRecords.header) }

    def tuning_line(lease,
                    line)
      store.append_tuning_line(scope: tuning_scope, tuning_run_id: tuning_id, line:, lease:)
    end

    it "keeps its records in <scope>/tuning/<tuning_run_id>/, as the record builders wrote them" do
      lease = tuning_lease
      TuningRecords.lines.each { tuning_line(lease, _1) }
      store.write_tuning_summary(scope: tuning_scope, tuning_run_id: tuning_id, summary: TuningRecords.summary, lease:)
      store.request_cancel(scope: tuning_scope, tuning_run_id: tuning_id, actor: Smith::Evals::Actor.person("u"),
                           reason: nil)
      lease.release

      expect(Dir.children(File.dirname(tuning_dir, 2)).sort).to eq(%w[scope.json tuning])
      expect(Dir.children(tuning_dir).sort).to eq(%w[cancel.json header.json lease lines.jsonl summary.json tmp])
      %w[header.json lines.jsonl summary.json].each do |name|
        expect(File.binread(File.join(tuning_dir, name))).to eq(TuningRecords.text(name).b), name
      end
      expect(store.list_records(scope: tuning_scope)["records"]).to eq([])
    end

    it "skips a torn last line, which the next lease holder cuts back to its last line feed" do
      first = "#{json(TuningRecords.lines.first)}\n".b
      File.binwrite(File.join(tuning_dir, "lines.jsonl"), first + json(TuningRecords.lines[1]).byteslice(0, 100))

      expect(store.each_tuning_line(scope: tuning_scope, tuning_run_id: tuning_id).map { json(_1) })
        .to eq([first.chomp])
      tuning_lease.release
      expect(File.binread(File.join(tuning_dir, "lines.jsonl"))).to eq(first)
    end
  end

  describe "torn and corrupt lines" do
    let(:lines) { EvalRecords.trials.first(2).map { "#{json(_1)}\n".b } }

    before { created! }

    it "skips a torn last line on read, which the next lease holder cuts back to its last line feed" do
      fragment = json(EvalRecords.trials[2]).byteslice(0, 1000)
      segment = "#{json(EvalRecords.segments.first)}\n".b
      File.binwrite(path("trials.jsonl"), lines.join + fragment)
      File.binwrite(path("segments.jsonl"), "#{segment}{\"format\":")

      expect(trials.map { json(_1) }).to eq(lines.map(&:chomp))
      expect(store.each_segment(scope:, eval_run_id: run_id).count).to eq(1)
      store.acquire_lease(scope:, eval_run_id: run_id).release
      expect([File.binread(path("trials.jsonl")), File.binread(path("segments.jsonl"))]).to eq([lines.join, segment])

      File.binwrite(path("trials.jsonl"), fragment)
      store.acquire_lease(scope:, eval_run_id: run_id).release
      expect(File.size(path("trials.jsonl"))).to eq(0)
    end

    it "skips a last line without its line feed even when it is whole JSON; the next lease holder cuts it" do
      File.binwrite(path("trials.jsonl"), lines.join + json(EvalRecords.trials[2]))

      expect(trials.map { json(_1) }).to eq(lines.map(&:chomp))
      leased.release
      expect(File.binread(path("trials.jsonl"))).to eq(lines.join)
    end

    it "cuts what its own failed write left before the next append under the same lease" do
      lease = leased
      append(lease, EvalRecords.trials[0])
      allow_any_instance_of(File).to receive(:syswrite).and_wrap_original do |original, data|
        next original.call(data) unless original.receiver.path.end_with?("trials.jsonl")

        original.call(data.byteslice(0, 100))
        raise Errno::EIO
      end

      expect { append(lease, EvalRecords.trials[1]) }.to raise_error(Smith::Evals::StoreError)
      expect(File.binread(path("trials.jsonl"))).to eq(lines.first + lines.last.byteslice(0, 100))
      allow_any_instance_of(File).to receive(:syswrite).and_call_original
      expect(append(lease, EvalRecords.trials[1])).to eq(:appended)
      expect(File.binread(path("trials.jsonl"))).to eq(lines.join)
    end

    it "reads its ids again after a failed write, so a retry finds the line the failed write left whole" do
      lease = leased
      append(lease, EvalRecords.trials[0])
      failing = true
      %i[fsync fcntl].each do |name|
        allow_any_instance_of(File).to receive(name).and_wrap_original do |original, *args|
          if failing && original.receiver.path.end_with?("trials.jsonl")
            failing = false
            raise Errno::EIO
          end
          original.call(*args)
        end
      end

      expect { append(lease, EvalRecords.trials[1]) }.to raise_error(Smith::Evals::StoreError)
      expect(append(lease, EvalRecords.trials[1])).to eq(:exists)
      expect(File.binread(path("trials.jsonl"))).to eq(lines.join)
    end

    it "reads a line file's ids afresh with each lease, so a line another store appended meanwhile is known" do
      other = described_class.new(root:)
      lease = leased
      append(lease, EvalRecords.trials[0])
      lease.release
      lease = other.acquire_lease(scope:, eval_run_id: run_id)
      other.append_trial(scope:, eval_run_id: run_id, line: EvalRecords.trials[1], lease:)
      lease.release

      expect(append(leased, EvalRecords.trials[1])).to eq(:exists)
      expect(File.binread(path("trials.jsonl"))).to eq(lines.join)
    end

    it "raises RecordCorrupt with the line number for a complete line that does not parse" do
      bad = ["{not json", '{"a":1,"a":2}', "[1,2]", "", "\xFF\xFE", '{"a": /* c */ 1}', '{"a":"\q"}', "x" * (9 << 20)]

      bad.each do |text|
        File.binwrite(path("trials.jsonl"), lines.join + "#{text}\n".b + lines.first)
        seen = []
        expect { store.each_trial(scope:, eval_run_id: run_id).each { seen << _1 } }
          .to raise_error(Smith::Evals::RecordCorrupt, /trials.jsonl line 3/) { expect(_1.line).to eq(3) }
        expect(seen.size).to eq(2)
      end
      File.binwrite(path("segments.jsonl"), "{}\n[]\n")
      expect { store.each_segment(scope:, eval_run_id: run_id).to_a }
        .to raise_error(Smith::Evals::RecordCorrupt, /segments.jsonl line 2/)
    end

    it "reads at most 8 MiB and a byte of a line, so a line past the bound is refused without being held whole" do
      File.binwrite(path("trials.jsonl"), "#{lines.join}#{"x" * (20 << 20)}\n")
      largest = 0
      allow_any_instance_of(File).to receive(:gets).and_wrap_original do |original, *args|
        original.call(*args).tap { largest = [largest, _1.to_s.bytesize].max }
      end

      expect { trials }.to raise_error(Smith::Evals::RecordCorrupt, /line 3: is longer than 8388608 bytes/)
      expect(largest).to eq((8 << 20) + 1)
    end

    it "refuses a header, summary or cancel flag over 8 MiB without reading it" do
      store.request_cancel(scope:, eval_run_id: run_id, actor: Smith::Evals::Actor.person("usr_1"), reason: nil)
      %w[header.json summary.json cancel.json].each { File.binwrite(path(_1), %({"a":"#{"x" * (8 << 20)}"})) }

      %i[read_header read_summary cancel_request].each do |call|
        expect { store.public_send(call, scope:, eval_run_id: run_id) }
          .to raise_error(Smith::Evals::RecordCorrupt, /is over 8388608 bytes/), call.to_s
      end
    end

    it "keeps a corrupt line when it cuts a torn tail, and refuses to append after it" do
      File.binwrite(path("trials.jsonl"), "#{lines.first}{oops}\n#{lines.last.chomp}")
      lease = store.acquire_lease(scope:, eval_run_id: run_id)

      expect(File.binread(path("trials.jsonl"))).to eq("#{lines.first}{oops}\n".b)
      expect { store.append_trial(scope:, eval_run_id: run_id, line: EvalRecords.trial_for(run_id, 7), lease:) }
        .to raise_error(Smith::Evals::RecordCorrupt, /line 2/)
    end

    it "raises RecordCorrupt for a header, summary or cancel flag edited into something else" do
      store.request_cancel(scope:, eval_run_id: run_id, actor: Smith::Evals::Actor.person("usr_1"), reason: nil)
      %w[summary.json cancel.json header.json].each { File.binwrite(path(_1), '{"a":1,"a":2}') }

      expect { store.read_summary(scope:, eval_run_id: run_id) }.to raise_error(Smith::Evals::RecordCorrupt, /summary/)
      expect { store.cancel_request(scope:, eval_run_id: run_id) }.to raise_error(Smith::Evals::RecordCorrupt, /cancel/)
      expect { store.read_header(scope:, eval_run_id: run_id) }.to raise_error(Smith::Evals::RecordCorrupt, /header/)
      expect(store.list_records(scope:)["unreadable"].map { _1["eval_run_id"] }).to eq([run_id])
    end
  end

  describe "listing" do
    def run_path(number, name) = File.join(scope_dir, "runs", EvalRecords.run_id(number), name)
    def ids(entries) = entries.map { _1["eval_run_id"] }

    def made(number)
      id = EvalRecords.run_id(number)
      store.create_record(scope:, header: EvalRecords.header_for(id, created_at: "2026-11-21T07:30:0#{number}Z"))
      lease = store.acquire_lease(scope:, eval_run_id: id)
      store.write_summary(scope:, eval_run_id: id, summary: EvalRecords.summary_for(id), lease:)
      lease.release
    end

    # A header that does not read has no place in the order, so the first
    # page names it; a summary that does not read, the page its run is on.
    it "skips a run it cannot read and names it once in a walk, so one bad record never breaks a scope's listing" do
      (1..5).each { made(_1) }
      File.binwrite(run_path(2, "header.json"), '{"a":1,"a":2}')
      FileUtils.cp(run_path(1, "header.json"), run_path(3, "header.json"))
      File.binwrite(run_path(4, "summary.json"), "{")
      running = EvalRecords.summary_for(EvalRecords.run_id(5), status: "running")
      File.binwrite(run_path(5, "summary.json"), "#{JSON.pretty_generate(running)}\n")

      listing = store.list_records(scope:)
      expect(ids(listing["records"])).to eq([EvalRecords.run_id(1)])
      expect(ids(listing["unreadable"])).to eq([2, 3, 4, 5].map { EvalRecords.run_id(_1) })
      expect(listing["unreadable"].map { _1["problem"] })
        .to match([2, 3, 4, 5].zip(%w[header header summary summary]).map do |number, name|
          %r{runs/#{EvalRecords.run_id(number)}/#{name}\.json}
        end)
      seen = { "records" => [], "unreadable" => [] }
      page = store.list_records(scope:, limit: 1)
      loop do
        seen.each_key { seen[_1] += ids(page[_1]) }
        break unless page["next"]

        page = store.list_records(scope:, limit: 1, after: page["next"])
      end
      expect(seen).to eq("records" => [EvalRecords.run_id(1)],
                         "unreadable" => [2, 3, 5, 4].map { EvalRecords.run_id(_1) })
    end
  end

  describe "readers beside a writer" do
    it "never yields a partial line while another process appends" do
      script = <<~RUBY
        STORE.create_record(scope: SCOPE, header: HEADER)
        lease = STORE.acquire_lease(scope: SCOPE, eval_run_id: RUN)
        puts "ready"
        sizes = [10, 1_000, 70_000, 300_000]
        150.times do |number|
          STORE.append_trial(scope: SCOPE, eval_run_id: RUN, line: line(number, output: "q" * sizes[number % 4]), lease:)
        end
        puts "done"
      RUBY
      counts = []
      child(script) do |input, output, waiter|
        input.close
        expect(output.gets).to eq("ready\n")
        while waiter.alive?
          read = trials.map { _1["trial_id"] }
          expect(read).to eq(read.size.times.map { EvalRecords.trial_id(_1) })
          counts << read.size
        end
        expect(output.read).to eq("done\n")
      end

      expect(counts).to eq(counts.sort)
      expect(trials.size).to eq(150)
    end

    it "cuts a torn tail by replacing the file, so a reader already reading never sees a mixed line" do
      created!
      lease = store.acquire_lease(scope:, eval_run_id: run_id)
      store.append_trial(scope:, eval_run_id: run_id, line: EvalRecords.trial_for(run_id, 1), lease:)
      lease.release
      torn = EvalRecords.trial_for(run_id, 2, output: "y" * 2_000_000)
      File.open(path("trials.jsonl"), "ab") { _1.write(json(torn).byteslice(0, 1_000_000)) }
      reader = store.each_trial(scope:, eval_run_id: run_id)
      expect(reader.next["trial_id"]).to eq(EvalRecords.trial_id(1))

      lease = store.acquire_lease(scope:, eval_run_id: run_id)
      store.append_trial(scope:, eval_run_id: run_id, line: EvalRecords.trial_for(run_id, 3, output: "z" * 2_000_000),
                         lease:)
      expect { reader.next }.to raise_error(StopIteration)
      expect(trials.map { _1["trial_id"] }).to eq([1, 3].map { EvalRecords.trial_id(_1) })
    end
  end

  describe "across processes" do
    # Children started together: each says "ready" once loaded, and goes on
    # when the parent writes a line.
    def together(script, args)
      children = started(script, args)
      results = children.map { _1[1].gets&.split }
      children.each { ended(*_1) }
      results
    end

    def started(script, args)
      children = args.map { Open3.popen2(*command(script, *_1)) }
      expect(children.map { _1[1].gets }).to all(eq("ready\n"))
      children.each { _1.first.puts("go") }
    end

    def ended(input, output, waiter)
      input.close
      finished(waiter)
      output.close
    end

    it "frees a lease when its process dies, kill -9 included" do
      created!
      script = <<~RUBY
        STORE.acquire_lease(scope: SCOPE, eval_run_id: RUN)
        puts "held"
        $stdin.read
      RUBY
      child(script) do |_input, output, waiter|
        expect(output.gets).to eq("held\n")
        expect { store.acquire_lease(scope:, eval_run_id: run_id) }.to raise_error(Smith::Evals::RunBusy)
        expect { described_class.new(root:).acquire_lease(scope:, eval_run_id: run_id) }
          .to raise_error(Smith::Evals::RunBusy)
        killed(waiter)
      end

      store.acquire_lease(scope:, eval_run_id: run_id).release
    end

    # The reviewer's case: the lease, then fork; the child may neither write
    # under it nor keep the run leased once the parent lets go.
    it "keeps a lease to the process that took it: a forked child cannot write under it or hold the run" do
      created!
      lease = leased
      append(lease, EvalRecords.trial_for(run_id, 1))
      reader, writer = IO.pipe
      forked = fork do
        reader.close
        said = begin
          append(lease, EvalRecords.trial_for(run_id, 2))
        rescue ArgumentError => e
          e.message
        end
        lease.release
        writer.puts(said)
        writer.close
        sleep
      ensure
        Process.exit!(0)
      end
      writer.close

      expect(reader.gets).to eq("the lease on eval run #{run_id} belongs to another process\n")
      expect { described_class.new(root:).acquire_lease(scope:, eval_run_id: run_id) }
        .to raise_error(Smith::Evals::RunBusy)
      expect(append(lease, EvalRecords.trial_for(run_id, 2))).to eq(:appended)
      lease.release
      described_class.new(root:).acquire_lease(scope:, eval_run_id: run_id).release
      expect(trials.map { _1["trial_id"] }).to eq([1, 2].map { EvalRecords.trial_id(_1) })
    ensure
      if forked
        Process.kill("KILL", forked)
        Process.wait(forked)
      end
    end

    it "frees a lease when its holder dies, kill -9 included, while a child it forked lives on" do
      created!
      # The forked child says "hooked" from its block, which runs after the
      # fork hook, so the holder is killed only once the child closed its copy;
      # it then waits on its input, which this process holds open, so it lives
      # until the cleanup kills it.
      script = <<~RUBY
        STORE.acquire_lease(scope: SCOPE, eval_run_id: RUN)
        forked = fork { puts "hooked"; $stdin.read }
        puts forked
        $stdin.read
      RUBY
      child(script) do |input, output, waiter|
        said = 2.times.map { output.gets }
        forked = Integer(said.find { _1.match?(/\A\d+\n\z/) })
        expect(said).to include("hooked\n")
        expect { leased }.to raise_error(Smith::Evals::RunBusy)
        killed(waiter)

        leased.release
        expect(Process.kill(0, forked)).to eq(1)
      ensure
        Process.kill("KILL", forked) if forked
        input.close
      end
    end

    # A fork while another thread is inside a write: nothing the child keeps
    # makes the parent's next write wait.
    it "never makes the parent's next write wait on a child forked in the middle of one" do
      created!
      lease = leased
      inside = Queue.new
      go = Queue.new
      paused = false
      allow_any_instance_of(File).to receive(:syswrite).and_wrap_original do |original, data|
        if original.receiver.path.end_with?("trials.jsonl") && !paused
          paused = true
          inside << true
          go.pop
        end
        original.call(data)
      end
      writer = Thread.new { append(lease, EvalRecords.trial_for(run_id, 1)) }
      inside.pop
      forked = fork do
        sleep
      ensure
        Process.exit!(0)
      end
      go << true
      writer.join
      later = Thread.new { append(lease, EvalRecords.trial_for(run_id, 2)) }

      expect(later.join(10)).not_to be_nil, "the parent's write waited on the child"
    ensure
      if forked
        Process.kill("KILL", forked)
        Process.wait(forked)
      end
      later&.join
    end

    # A fork while another thread is inside acquire_lease: the lease file is
    # noted as soon as it is open, so the child closes its copy too. The
    # child's block runs after the hook, so its word is the signal to go on.
    it "frees the run when a child forked while another thread was taking the lease lives on" do
      created!
      inside = Queue.new
      go = Queue.new
      paused = false
      allow(Dir).to receive(:children).and_wrap_original do |original, folder|
        if folder == path("tmp") && !paused
          paused = true
          inside << true
          go.pop
        end
        original.call(folder)
      end
      taker = Thread.new { leased }
      inside.pop
      reader, writer = IO.pipe
      forked = fork do
        writer.puts("hooked")
        sleep
      ensure
        Process.exit!(0)
      end
      writer.close
      expect(reader.gets).to eq("hooked\n")
      go << true
      taker.value.release

      described_class.new(root:).acquire_lease(scope:, eval_run_id: run_id).release
    ensure
      if forked
        Process.kill("KILL", forked)
        Process.wait(forked)
      end
    end

    it "leaves no descriptor open when a lease cannot be taken" do
      created!
      allow_any_instance_of(File).to receive(:flock).and_raise(Errno::EIO)
      GC.disable

      expect { leased }.to raise_error(Smith::Evals::StoreError)
      expect(ObjectSpace.each_object(File).count { _1.path == path("lease") && !_1.closed? }).to eq(0)
    ensure
      GC.enable
    end

    it "creates a record once and leases it once among four racing processes" do
      script = <<~RUBY
        puts "ready"
        $stdin.gets
        created = STORE.create_record(scope: SCOPE, header: HEADER)
        leased = begin
          STORE.acquire_lease(scope: SCOPE, eval_run_id: RUN) && "leased"
        rescue Smith::Evals::RunBusy
          "busy"
        end
        puts "\#{created} \#{leased}"
        $stdin.read
      RUBY

      expect(together(script, [[]] * 4).transpose.map(&:tally))
        .to eq([{ "created" => 1, "exists" => 3 }, { "leased" => 1, "busy" => 3 }])
    end

    it "loses nothing when two processes write two runs of one scope, each cancelling the other's" do
      script = <<~RUBY
        number = Integer(ARGV.first)
        run = format("er_%032x", number)
        STORE.create_record(scope: SCOPE, header: HEADER.merge("eval_run_id" => run))
        lease = STORE.acquire_lease(scope: SCOPE, eval_run_id: run)
        puts "ready"
        $stdin.gets
        100.times { STORE.append_trial(scope: SCOPE, eval_run_id: run, line: line(_1, run:), lease:) }
        STORE.request_cancel(scope: SCOPE, eval_run_id: format("er_%032x", 3 - number),
                             actor: { "kind" => "service", "id" => run }, reason: nil)
        puts "done"
      RUBY

      expect(together(script, [["1"], ["2"]])).to eq([["done"], ["done"]])
      [1, 2].each do |number|
        id = EvalRecords.run_id(number)
        expect(store.each_trial(scope:, eval_run_id: id).count).to eq(100)
        expect(store.cancel_request(scope:, eval_run_id: id).dig("actor", "id")).to eq(EvalRecords.run_id(3 - number))
      end
      expect(store.list_records(scope:)["records"].size).to eq(2)
    end
  end

  describe "paths" do
    let(:outside) { File.join(@dir, "outside").tap { FileUtils.mkdir_p(_1) } }
    let(:target) { File.join(outside, "file.json") }

    # Each place the store reads or writes, a call that reaches it, and
    # whether the record exists before the place becomes a link.
    let(:places) do
      line = EvalRecords.trial_for(run_id, 1)
      create = -> { store.create_record(scope:, header: EvalRecords.header) }
      # The lease is released whatever happens, so a case never leaves a lock
      # behind for the next one.
      append = lambda do
        lease = store.acquire_lease(scope:, eval_run_id: run_id)
        store.append_trial(scope:, eval_run_id: run_id, line:, lease:)
      ensure
        lease&.release
      end
      {
        File.join(root, "v1") => [create, false], File.join(root, "v1", "scopes") => [create, false],
        scope_dir => [create, false], File.join(scope_dir, "runs") => [-> { store.list_records(scope:) }, true],
        run_dir => [-> { store.read_header(scope:, eval_run_id: run_id) }, true], path("tmp") => [create, true],
        File.join(scope_dir, "scope.json") => [create, true],
        path("header.json") => [-> { store.read_header(scope:, eval_run_id: run_id) }, true],
        path("summary.json") => [-> { store.read_summary(scope:, eval_run_id: run_id) }, true],
        path("cancel.json") => [-> { store.cancel_request(scope:, eval_run_id: run_id) }, true],
        path("lease") => [append, true], path("trials.jsonl") => [append, true],
        path("segments.jsonl") => [-> { store.each_segment(scope:, eval_run_id: run_id).to_a }, true]
      }
    end

    it "never follows a link out of its root, at any folder or file it uses" do
      places.each do |place, (call, recorded)|
        FileUtils.rm_rf(root)
        File.write(target, "kept")
        created! if recorded
        FileUtils.rm_rf(place)
        FileUtils.mkdir_p(File.dirname(place))
        File.symlink(File.extname(place).empty? && !place.end_with?("lease") ? outside : target, place)

        expect { call.call }.to raise_error(Smith::Evals::StoreError, /is a link/), place
        expect([Dir.children(outside), File.read(target)]).to eq([["file.json"], "kept"]), place
      end
    end

    it "refuses to append to or replace a file with another link, so a hard link never takes a write outside" do
      created!
      lease = leased
      lines_out = File.join(outside, "lines.jsonl").tap { File.write(_1, "") }
      summary_out = File.join(outside, "summary.json").tap { File.write(_1, "{}\n") }
      File.link(lines_out, path("trials.jsonl"))
      File.link(summary_out, path("summary.json"))

      expect { append(lease, EvalRecords.trials.first) }
        .to raise_error(Smith::Evals::StoreError, /trials.jsonl has another link, which the store never makes/)
      expect { store.write_summary(scope:, eval_run_id: run_id, summary: EvalRecords.first_summary, lease:) }
        .to raise_error(Smith::Evals::StoreError, /summary.json has another link/)
      lease.release
      File.write(lines_out, '{"torn')
      expect { leased }.to raise_error(Smith::Evals::StoreError, /trials.jsonl has another link/)
      expect([File.read(lines_out), File.read(summary_out)]).to eq(['{"torn', "{}\n"])
    end

    it "refuses anything but a regular file, never blocking on a FIFO" do
      created!
      store.request_cancel(scope:, eval_run_id: run_id, actor: Smith::Evals::Actor.person("usr_1"), reason: nil)
      %w[header.json summary.json cancel.json trials.jsonl segments.jsonl lease].each do |name|
        FileUtils.rm_f(path(name))
        File.mkfifo(path(name))
      end
      script = <<~RUBY
        calls = {
          "header" => -> { STORE.read_header(scope: SCOPE, eval_run_id: RUN) },
          "summary" => -> { STORE.read_summary(scope: SCOPE, eval_run_id: RUN) },
          "cancel" => -> { STORE.cancel_request(scope: SCOPE, eval_run_id: RUN) },
          "trials" => -> { STORE.each_trial(scope: SCOPE, eval_run_id: RUN).to_a },
          "segments" => -> { STORE.each_segment(scope: SCOPE, eval_run_id: RUN).to_a },
          "lease" => -> { STORE.acquire_lease(scope: SCOPE, eval_run_id: RUN) },
          "list" => lambda {
            problem = STORE.list_records(scope: SCOPE)["unreadable"].map { _1["problem"] }.join
            raise Smith::Evals::StoreError.new(problem, operation: :list_records)
          }
        }
        calls.each do |name, call|
          call.call
          puts "\#{name} read"
        rescue Smith::Evals::StoreError => e
          puts "\#{name} \#{e.message[/not a regular file/]}"
        end
      RUBY
      child(script) do |input, output, waiter|
        input.close
        finished(waiter)
        expect(output.read.lines(chomp: true))
          .to eq(%w[header summary cancel trials segments lease list].map { "#{_1} not a regular file" })
      end
    end

    it "refuses a folder where a record's file belongs" do
      created!
      FileUtils.rm_f(path("header.json"))
      FileUtils.mkdir_p(path("header.json"))

      expect { store.read_header(scope:, eval_run_id: run_id) }
        .to raise_error(Smith::Evals::StoreError, /not a regular file/)
    end
  end
end
