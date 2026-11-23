# frozen_string_literal: true

require "fileutils"
require "json"
require "open3"
require "rbconfig"
require "tmpdir"

module CoreInvisibility
  # Where a golden file comes from, named by content: the git ids of the
  # parts of a tree that decide what the harness records (PARTS), taken
  # from a commit or from the staged index (never from unstaged edits), and
  # the commit that tree was built on, for reference. Each part is
  # extracted by its id into a folder of its own, with a bundle of its own
  # (smith-agents from that folder, every other gem installed, at the
  # versions the repository's Gemfile.lock holds when it has one, never the
  # network), and that folder's harness runs there in a child
  # process, which names the source only when the folder holds exactly
  # those parts (SourceFolder), so a working tree is never taken for one.
  # Once the parts are committed, anyone can extract them by their ids
  # (`git archive` takes a tree) and write the same golden again. Needs
  # nothing from Smith, so the parent process loads none.
  module GitSource
    ROOT = File.expand_path("../..", __dir__)
    # Smith's code and the gemspec its bundle resolves from, the harness,
    # and the local server it answers through. The repository's Gemfile is
    # not one: the golden bundle's is GEMFILE_TEXT, part of the harness.
    PARTS = %w[lib smith-agents.gemspec script/core_invisibility_golden script/golden spec/support/sse_server.rb].freeze
    ID = /\A\h{40}\z/
    MARKER = ".smith-golden-source"
    GEMFILE = "Gemfile.golden"
    OWN = [MARKER, GEMFILE, "#{GEMFILE}.lock"].freeze
    # The repository a child looks its source's ids up in.
    REPOSITORY = "SMITH_GOLDEN_REPOSITORY"
    GEMFILE_TEXT = <<~RUBY
      # frozen_string_literal: true

      # The golden bundle: smith-agents from this folder of a source's parts.
      source "https://rubygems.org"
      gem "smith-agents", path: __dir__
    RUBY

    class Refused < StandardError; end

    module_function

    # A commit's parts.
    def from_commit(ref, repo: ROOT)
      id = commit_id(ref, repo:)
      { "source" => "commit", "built_on" => id, "parts" => parts_of(id, repo:) }
    end

    def commit_id(ref, repo: ROOT) = git("rev-parse", "--verify", "--quiet", "#{ref}^{commit}", repo:).strip

    # The staged index's parts (`git write-tree` stores its trees), on the
    # commit checked out.
    def from_index(repo: ROOT)
      tree = git("write-tree", repo:).strip
      { "source" => "index", "built_on" => git("rev-parse", "--verify", "HEAD", repo:).strip,
        "parts" => parts_of(tree, repo:) }
    end

    # The source a golden file names, to write it again.
    def from_golden(path)
      source = JSON.parse(File.read(path)).fetch("smith", {}).slice("source", "built_on", "parts")
      named?(source) ? source : raise(Refused, "#{path} names no git source")
    end

    def parts_of(tree, repo: ROOT)
      PARTS.to_h { [_1, git("rev-parse", "--verify", "--quiet", "#{tree}:#{_1}", repo:).strip] }
    end

    def named?(source)
      parts = source.is_a?(Hash) && source["parts"]
      parts.is_a?(Hash) && parts.keys == PARTS && [source["built_on"], *parts.values].all? { _1.to_s.match?(ID) } &&
        %w[index commit].include?(source["source"])
    end

    # Writes the golden file at `path` from `source`; true when the child
    # wrote it.
    def write_golden(source, path, repo: ROOT)
      Dir.mktmpdir("smith-golden-") do |dir|
        extract(source, dir, repo:)
        bundle!(dir, repo:)
        env, *command = writer(dir, File.expand_path(path), repo:)
        unbundled { system(env, *command) }
      end
    end

    # Each part by its id at its path in `into`, with the marker naming the
    # source and the golden bundle's Gemfile beside them.
    def extract(source, into, repo: ROOT)
      source.fetch("parts").each { |part, id| unpack(part, id, into, repo) }
      File.write(File.join(into, MARKER), "#{JSON.generate(source)}\n")
      File.write(File.join(into, GEMFILE), GEMFILE_TEXT)
    end

    # A tree as `git archive` gives it, a blob as `git cat-file` does.
    def unpack(part, id, into, repo)
      target = File.join(into, part)
      unless git("cat-file", "-t", id, repo:).strip == "tree"
        FileUtils.mkdir_p(File.dirname(target))
        return File.binwrite(target, git("cat-file", "blob", id, repo:))
      end

      archive = git("archive", "--format=tar", "--prefix=#{part}/", id, repo:)
      _out, err, status = Open3.capture3("tar", "-x", "-C", into, stdin_data: archive, binmode: true)
      raise Refused, "could not unpack #{part} #{id}: #{err}" unless status.success?
    end

    # The bundle resolves the versions the repository's Gemfile.lock holds
    # (its specs run with them), the newest installed gems without one.
    def bundle!(dir, repo: ROOT)
      lock = File.join(ROOT, "Gemfile.lock")
      FileUtils.cp(lock, File.join(dir, "#{GEMFILE}.lock")) if File.file?(lock)
      env = bundle_env(dir, repo:)
      ok = unbundled { system(env, RbConfig.ruby, "-S", "bundle", "install", "--local", "--quiet") }
      raise Refused, "the golden bundle for #{dir} did not install from local gems" unless ok
    end

    # The child: the folder's own harness, in the folder's bundle.
    def harness(dir, *arguments, repo: ROOT)
      [bundle_env(dir, repo:), RbConfig.ruby, "-S", "bundle", "exec", RbConfig.ruby,
       File.join(dir, "script/core_invisibility_golden"), *arguments]
    end

    def writer(dir, path, repo: ROOT) = harness(dir, "--write", path, repo:)

    # The golden bundle's processes run outside this one's bundle, so they
    # are handed the gems this one sees (a vendored bundle's among them),
    # and the repository the source's ids are in.
    def bundle_env(dir, repo: ROOT)
      { "BUNDLE_GEMFILE" => File.join(dir, GEMFILE), "GEM_HOME" => Gem.dir,
        "GEM_PATH" => Gem.path.join(File::PATH_SEPARATOR), REPOSITORY => repo }
    end

    # A child is handed the repository; the parent's is its own.
    def git(*args, input: nil, repo: ENV.fetch(REPOSITORY, ROOT))
      out, err, status = Open3.capture3("git", "-C", repo, *args, stdin_data: input.to_s, binmode: true)
      raise Refused, "git #{args.first}: #{err.strip}" unless status.success?

      out
    end

    def unbundled(&)
      defined?(Bundler) ? Bundler.with_unbundled_env(&) : yield
    end
  end
end
