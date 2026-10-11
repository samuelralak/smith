# frozen_string_literal: true

module Smith
  # One run a `map`, `call` or `spawn` step asks the host's run launcher to
  # start: its `ref` (the index of its item, so the same on every replay of
  # the step), its workflow class, the context `input:` returned for it, and
  # the untrusted keys it inherits from its parent (the parent's untrusted
  # keys that `input:` passed under the same names).
  ChildRun = Data.define(:ref, :workflow, :input, :untrusted_keys) do
    # The child, built with its inherited untrusted keys in force; they
    # persist with it, so a restored child keeps them.
    def build
      Workflow::StepIO.with_inherited_untrusted_keys(untrusted_keys) { workflow.new(context: input) }
    end

    # The entry a host reports for a finished child when it resumes the
    # parent: `{ ref:, status: "succeeded" | "failed", state:, output: }`.
    def self.result(ref:, run_result:)
      { ref:, status: run_result.failed? ? "failed" : "succeeded", state: run_result.state&.to_s,
        output: run_result.output }
    end
  end
end
