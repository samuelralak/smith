# frozen_string_literal: true

require "digest"
require "json"

module Smith
  # One run a `map`, `call` or `spawn` step asks the host's run launcher to
  # start: its `ref` (the index of its item, so the same on every replay of
  # the step), its `key` (what the launcher must be idempotent on: the
  # same on every launch of the child, and no other child of any run has
  # it), its workflow class, the context `input:` returned for it,
  # the untrusted keys it inherits from its parent (the parent's untrusted
  # keys that `input:` passed under the same names), and the artifact
  # namespaces it may read (its parent's and the parent's ancestors', the
  # nearest first), so a document a parent stored reaches its children.
  ChildRun = Data.define(:ref, :key, :workflow, :input, :untrusted_keys, :artifact_namespaces) do
    # The key of the step's `ref`th child, from the step's token. A step in
    # an in-process nested workflow or a fan-out item shares the run's
    # tokens with the steps of its number elsewhere in the run, so its
    # `place` (the positions above it there) is in its children's keys
    # too. At the run's root `place` is empty, and the key is 0.16.0's.
    def self.key_for(await_token, ref, place = [])
      return Digest::SHA256.hexdigest("smith.child_run.v1:#{await_token}:#{ref}") if place.empty?

      Digest::SHA256.hexdigest(JSON.generate(["smith.child_run.v1", await_token, place, ref]))
    end

    def initialize(artifact_namespaces: [], **)
      super
    end

    # The child, built with what it inherits in force; both persist with
    # it, so a restored child keeps them.
    def build
      Workflow::StepIO.with_inherited_untrusted_keys(untrusted_keys) do
        Workflow::ArtifactIntegration.with_inherited_artifact_namespaces(artifact_namespaces) do
          workflow.new(context: input)
        end
      end
    end

    # The entry a host reports for a finished child when it resumes the
    # parent: `{ ref:, status: "succeeded" | "failed", state:, output: }`.
    # A child failed when it ended in its failed state or any of its steps
    # raised, even one its own `on_failure` handled.
    def self.result(ref:, run_result:)
      failed = run_result.failed? || Array(run_result.steps).any? { _1.is_a?(Hash) && _1.key?(:error) }
      { ref:, status: failed ? "failed" : "succeeded", state: run_result.state&.to_s, output: run_result.output }
    end
  end
end
