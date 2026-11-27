# frozen_string_literal: true

require_relative "identity"
require_relative "../json_value"

module Smith
  module Evals
    # Experimental. The thing under test (slice-1a design, 4.5): a Smith
    # workflow class, the input mapping from a sample to the workflow's
    # context, the end-state keys a scorer may read (`keep`), an optional
    # state to stop at (`until:`), the mapping's author-declared version
    # (code cannot be hashed, so it stands in) and, for model comparison
    # (slice 1b), a `variants:` hook. Nothing is checked on construction, a
    # missing or unknown setting included; `problems` lists what a suite
    # refuses.
    class Subject
      MAX_KEEP = 64
      MAX_WORKFLOW_NAME = 256

      attr_reader :workflow, :input, :keep, :until_state, :version, :variants

      def initialize(workflow: nil, input: nil, keep: [], version: 1, variants: nil, until: nil, **unknown)
        @workflow = workflow
        @input = input
        @keep = keep.is_a?(Array) ? keep.dup.freeze : keep
        @until_state = binding.local_variable_get(:until)
        @version = version
        @variants = variants
        @unknown = unknown.keys.freeze
        freeze
      end

      # The workflow class a trial runs: the declared one, or for a model
      # comparison's variant (slice 1b) the one the `variants:` hook builds.
      def workflow_for(variant) = variant.nil? ? workflow : variants.call(variant)

      # "/subject/...: problem" lines.
      def problems
        @unknown.map { "/subject: unknown setting #{_1}" } +
          [workflow_problem, input_problem, keep_problem, until_problem, version_problem, variants_problem].compact
      end

      # The manifest's subject: the workflow's name, keep (sorted: a set of
      # keys), until, version.
      def to_manifest
        { "kind" => "workflow", "workflow" => workflow.name, "keep" => Identity.utf16_sort(keep.map(&:to_s)),
          "until" => until_state&.to_s, "version" => version }
      end

      private

      # A named class: a Smith::Workflow subclass for Smith's own driver, a
      # program of its own for a host driver.
      def workflow_problem
        name = workflow.name if workflow.is_a?(Class)
        return if name.is_a?(String) && name.length <= MAX_WORKFLOW_NAME

        "/subject/workflow: is a named class (a Smith::Workflow subclass, unless a host driver runs it)"
      end

      def input_problem = ("/subject/input: responds to call(sample)" unless input.respond_to?(:call))

      def keep_problem
        return "/subject/keep: is an Array of state keys" unless keep.is_a?(Array) && keep.all? { name?(_1) }
        return "/subject/keep: names at most #{MAX_KEEP} keys, not #{keep.size}" if keep.size > MAX_KEEP

        "/subject/keep: names a key twice" unless keep.map(&:to_s).uniq.size == keep.size
      end

      def until_problem = ("/subject/until: is nil or a state name" unless until_state.nil? || name?(until_state))

      def version_problem
        return if version.is_a?(Integer) && version.between?(1, CanonicalJSON::MAX_SAFE_INTEGER)

        "/subject/version: is an Integer from 1 to 2**53 - 1"
      end

      def variants_problem
        "/subject/variants: is nil or responds to call(variant)" unless variants.nil? || variants.respond_to?(:call)
      end

      def name?(value)
        (value.is_a?(Symbol) || value.is_a?(String)) && JSONValue.utf8?(value.to_s) &&
          value.to_s.length.between?(1, 128)
      end
    end
  end
end
