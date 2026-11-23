# frozen_string_literal: true

# The shared harness's scenarios (slice-1a design, section 3.5). Each runs
# against the local server answering as Anthropic, so RubyLLM's real
# provider code runs and nothing below Smith is stubbed. The list is frozen
# with slice 0: later slices only add scenarios, at the end.
module CoreInvisibility
  D = Define
  R = Replies

  D.schema("GoldenLabelSchema", { label: { type: "string" } })
  D.schema("GoldenRouteSchema", { route: { type: "string" }, confidence: { type: "number" } })
  D.schema("GoldenVerdictSchema", { accept: { type: "boolean" }, feedback: { type: "string" },
                                    score: { type: "number" } }, required: %i[accept feedback])
  D.schema("GoldenTaskSchema", { task_id: { type: "string" }, input: { type: "string" } })
  D.schema("GoldenFindingSchema", { finding: { type: "string" } }, string_keys: true)
  D.schema("GoldenSummarySchema", { summary: { type: "string" } })
  D.schema("GoldenDecisionSchema", {
             tasks: { type: "array", items: { type: "object", required: %w[task_id input],
                                              properties: { task_id: { type: "string" },
                                                            input: { type: "string" } } } },
             final: { type: "object", required: ["summary"], properties: { summary: { type: "string" } } }
           }, required: [])
  D.tool("GoldenLookup", ->(query) { { found: "#{query} opens at 8" } })

  # A one-step workflow asking `agent`, its answer kept under `into`.
  def self.asking(name, agent, into: :answer, ask: "Is the clinic open?", **step, &body)
    D.workflow(name) do
      initial_state :idle
      state :failed
      seed_messages { |_context| [{ role: :user, content: ask }] }
      transition :ask, from: :idle, to: :done do
        execute agent, output_to: into, **step
        instance_exec(&body) if body
        on_failure :fail
      end
    end
  end

  # Runs a fresh run to its end or its wait, persisted under `key`.
  def self.persisted(run, klass, key, context: {})
    workflow = klass.new(context:)
    result = run.capture { workflow.run_persisted!(key, adapter: run.adapter) }
    run.finish(workflow, result)
  end

  # Restores the run under `key` and runs it on.
  def self.resumed(run, klass, key)
    workflow = run.restore(klass, key)
    result = run.capture { workflow.run_persisted!(key, adapter: run.adapter) }
    run.finish(workflow, result)
  end
end

require_relative "scenarios/paths"
require_relative "scenarios/nesting"
require_relative "scenarios/loops"
require_relative "scenarios/modes"
require_relative "scenarios/budgets"
require_relative "scenarios/waits"
require_relative "scenarios/images"
require_relative "scenarios/items"
require_relative "scenarios/failures"
require_relative "scenarios/rounds"
require_relative "scenarios/paint_failures"
require_relative "scenarios/paint_agents"
require_relative "scenarios/item_paths"
require_relative "scenarios/ruby_llm_requests"
require_relative "scenarios/ruby_llm_replies"
