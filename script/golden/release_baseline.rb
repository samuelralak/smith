# frozen_string_literal: true

require "json"
require "open3"
require "tmpdir"
require_relative "git_source"

module CoreInvisibility
  # The release baseline: what the last release's Smith gives in the plain
  # mode, a fixture a golden's regeneration never writes. The golden moves
  # with every change that alters a record; this stays with the release, so
  # spec/smith/core_invisibility_spec.rb can hold the tree to it on what a
  # leak would show (the host surface, and each scenario's random draws,
  # lookups, requests, traces, events and log lines), every difference
  # listed there with why. Rewritten only at a release, from the release's commit:
  #   ruby script/core_invisibility_golden --write-release --commit v<version>
  # A release before the harness takes it from a later commit (--harness REF).
  # Written again from the ids it names (the spec does):
  #   ruby script/core_invisibility_golden --write-release /tmp/again.json --source-of
  module ReleaseBaseline
    PATH = File.join(GitSource::ROOT, "spec/fixtures/core_invisibility_release.json")
    FORMAT = "smith.core_invisibility.release/1"
    SMITH = %w[lib smith-agents.gemspec].freeze
    FACTS = %w[random_draws counts requests traces events logs].freeze

    module_function

    # Smith from the release's commit, the harness from `harness` (the
    # release's own, once it holds one).
    def from_commit(release, harness: release, repo: GitSource::ROOT)
      release, harness = [release, harness].map { GitSource.commit_id(_1, repo:) }
      parts = GitSource::PARTS.to_h do |part|
        from = SMITH.include?(part) ? release : harness
        [part, GitSource.git("rev-parse", "--verify", "--quiet", "#{from}:#{part}", repo:).strip]
      end
      { "version" => version_at(release, repo:), "source" => "release", "release" => release, "harness" => harness,
        "parts" => parts }
    end

    def from_baseline(path)
      source = JSON.parse(File.read(path)).fetch("smith", {})
      named?(source) ? source : raise(GitSource::Refused, "#{path} names no release source")
    end

    def named?(source)
      parts = source.is_a?(Hash) && source["parts"]
      source["source"] == "release" && parts.is_a?(Hash) && parts.keys == GitSource::PARTS &&
        [source["release"], source["harness"], *parts.values].all? { _1.to_s.match?(GitSource::ID) }
    end

    def version_at(commit, repo:)
      GitSource.git("show", "#{commit}:lib/smith/version.rb", repo:)[/VERSION = "([^"]+)"/, 1] ||
        raise(GitSource::Refused, "#{commit} names no Smith version")
    end

    # Writes the baseline at `path` from `source`: the parts by their ids in
    # a folder of their own and its bundle, the folder's harness run there
    # in the plain mode, and its document kept as the facts compared.
    def write(source, path, repo: GitSource::ROOT)
      document = Dir.mktmpdir("smith-release-") do |dir|
        source.fetch("parts").each { |part, id| GitSource.unpack(part, id, dir, repo) }
        File.write(File.join(dir, GitSource::GEMFILE), GitSource::GEMFILE_TEXT)
        GitSource.bundle!(dir, repo:)
        plain(dir, repo:)
      end
      File.write(path, "#{JSON.pretty_generate(baseline(source, document))}\n")
    end

    def plain(dir, repo:)
      out, err, status = GitSource.unbundled { Open3.capture3(*GitSource.harness(dir, "--mode", "plain", repo:)) }
      raise GitSource::Refused, "the release's harness failed: #{err}" unless status.success?

      JSON.parse(out)
    end

    def baseline(source, document)
      { "format" => FORMAT, "smith" => source, "environment" => document["environment"],
        "process" => document["process"], "host_surface" => document["host_surface"],
        "scenarios" => document["scenarios"].transform_values { facts(_1) } }
    end

    # What a plain run of a scenario shows of a leak: its random draws, the
    # counted lookups it made (by count; one never made is left out), how
    # many requests, traces (by type) and events (by class) it made, and how
    # many lines it logged.
    def facts(scenario)
      { "random_draws" => scenario["random_draws"], "counts" => scenario["counts"].reject { |_name, n| n.zero? },
        "requests" => scenario["requests"].length, "traces" => scenario["traces"].map { _1[":type"] }.tally,
        "events" => scenario["events"].map(&:first).tally, "logs" => logged(scenario) }
    end

    # Lines every logger wrote.
    def logged(scenario) = scenario["logs"].sum { |loggers| loggers.values.sum(&:length) }
  end
end
