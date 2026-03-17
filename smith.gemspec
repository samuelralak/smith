# frozen_string_literal: true

require_relative "lib/smith/version"

Gem::Specification.new do |spec|
  spec.name = "smith"
  spec.version = Smith::VERSION
  spec.authors = ["Samuel Ralak"]
  spec.email = ["thesamuelralak@gmail.com"]

  spec.summary = "Workflow-first multi-agent orchestration for Ruby"
  spec.description = "Smith is a workflow-first multi-agent orchestration library built on RubyLLM. " \
                     "It provides state machine modeling, typed contracts, budget enforcement, " \
                     "guardrails, and observability for agent workflows."
  spec.homepage = "https://github.com/samuelralak/smith"
  spec.license = "MIT"
  spec.required_ruby_version = ">= 3.2.0"

  spec.metadata["homepage_uri"] = spec.homepage
  spec.metadata["source_code_uri"] = "https://github.com/samuelralak/smith"
  spec.metadata["changelog_uri"] = "https://github.com/samuelralak/smith/blob/main/CHANGELOG.md"

  gemspec = File.basename(__FILE__)
  spec.files = IO.popen(%w[git ls-files -z], chdir: __dir__, err: IO::NULL) do |ls|
    ls.readlines("\x0", chomp: true).reject do |f|
      (f == gemspec) ||
        f.start_with?(*%w[bin/ Gemfile .gitignore .rspec spec/ .rubocop.yml])
    end
  end
  spec.bindir = "exe"
  spec.executables = spec.files.grep(%r{\Aexe/}) { |f| File.basename(f) }
  spec.require_paths = ["lib"]

  spec.add_dependency "ruby_llm", "~> 1.13"
  spec.add_dependency "aasm", "~> 5.5"
  spec.add_dependency "dry-types", "~> 1.7"
  spec.add_dependency "dry-struct", "~> 1.6"
  spec.add_dependency "dry-initializer", "~> 3.1"
  spec.add_dependency "dry-configurable", "~> 1.0"
  spec.add_dependency "dry-container", "~> 0.11"
end
