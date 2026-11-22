# frozen_string_literal: true

require "open3"
require "rbconfig"
require "tmpdir"

module CoreInvisibility
  # A golden file written from a named commit of this repository: the
  # commit's files as `git archive` gives them, in a folder of their own with
  # a bundle of their own (smith-agents from that folder, everything else
  # resolved from installed gems, never the network), the harness run there
  # in a child process. The child names the commit only when the folder holds
  # exactly that commit's files, so a working tree, with its edits and
  # untracked files, is never taken for one. The commit named is that of
  # Smith's code; the harness that runs is this tree's, as with a release.
  # Needs nothing from Smith, so the parent process loads none.
  module CommitSource
    ROOT = File.expand_path("../..", __dir__)
    SCRIPT = File.join(ROOT, "script/core_invisibility_golden")
    MARKER = ".smith-golden-commit"
    GEMFILE = "Gemfile.golden"
    OWN = [MARKER, GEMFILE, "#{GEMFILE}.lock"].freeze
    GEMFILE_TEXT = <<~RUBY
      # frozen_string_literal: true

      # The bundle a golden file is written in: smith-agents from this
      # git archive of a commit (script/golden/commit_source.rb).
      source "https://rubygems.org"

      gem "smith-agents", path: __dir__
    RUBY

    class Refused < StandardError; end

    module_function

    # Writes the golden file at `path` from the commit `ref` names; true when
    # the child wrote it.
    def write_golden(ref, path)
      Dir.mktmpdir("smith-golden-") do |dir|
        extract(ref, dir)
        bundle!(dir)
        env, *command = writer(dir, File.expand_path(path))
        unbundled { system(env, *command) }
      end
    end

    # The commit's files in `into`, with the marker naming it and the
    # golden bundle's Gemfile beside them. Returns the commit's id.
    def extract(ref, into)
      id = git("rev-parse", "--verify", "--quiet", "#{ref}^{commit}").strip
      archive = git("archive", "--format=tar", id)
      _out, err, status = Open3.capture3("tar", "-x", "-C", into, stdin_data: archive, binmode: true)
      raise Refused, "could not unpack #{id}: #{err}" unless status.success?

      File.write(File.join(into, MARKER), "#{id}\n")
      File.write(File.join(into, GEMFILE), GEMFILE_TEXT)
      id
    end

    def bundle!(dir)
      env = bundle_env(dir)
      ok = unbundled { system(env, RbConfig.ruby, "-S", "bundle", "install", "--local", "--quiet") }
      raise Refused, "the golden bundle for #{dir} did not install from local gems" unless ok
    end

    # The child: the harness, writing in the commit's bundle.
    def writer(dir, path)
      [bundle_env(dir), RbConfig.ruby, "-S", "bundle", "exec", RbConfig.ruby, SCRIPT, "--write", path]
    end

    # The golden bundle's processes run outside this one's bundle, so they
    # are handed the gems this one sees (a vendored bundle's among them).
    def bundle_env(dir)
      { "BUNDLE_GEMFILE" => File.join(dir, GEMFILE), "GEM_HOME" => Gem.dir,
        "GEM_PATH" => Gem.path.join(File::PATH_SEPARATOR) }
    end

    # The commit's id when `root` holds exactly its files (the marker and
    # the bundle's own files aside), each byte for byte, and the bundle's
    # Gemfile, Ruby the bundle runs, is the one written here; nil otherwise.
    def verified(root)
      id = marked(root)
      return unless id && own_gemfile?(root)

      expected = blobs(id)
      files = Dir.glob("**/*", File::FNM_DOTMATCH, base: root).select { File.file?(File.join(root, _1)) } - OWN
      id if files.sort == expected.keys.sort && hashed(root, files) == files.map { expected.fetch(_1) }
    rescue Refused
      nil
    end

    def own_gemfile?(root)
      gemfile = File.join(root, GEMFILE)
      File.file?(gemfile) && File.read(gemfile) == GEMFILE_TEXT
    end

    def marked(root)
      marker = File.join(root, MARKER)
      id = File.file?(marker) && File.read(marker).strip
      id if id&.match?(/\A\h{40}\z/)
    end

    # { path => blob id } for every file the commit holds.
    def blobs(id)
      git("ls-tree", "-r", "-z", "--full-tree", id).split("\0").to_h do |entry|
        meta, path = entry.split("\t", 2)
        [path, meta.split.last]
      end
    end

    # The blob ids of the files as they are, written nowhere.
    def hashed(root, files)
      git("hash-object", "--no-filters", "--stdin-paths", input: files.map { File.join(root, _1) }.join("\n")).split
    end

    def git(*args, input: nil)
      out, err, status = Open3.capture3("git", "-C", ROOT, *args, stdin_data: input.to_s, binmode: true)
      raise Refused, "git #{args.first}: #{err.strip}" unless status.success?

      out
    end

    def unbundled(&)
      defined?(Bundler) ? Bundler.with_unbundled_env(&) : yield
    end
  end
end
