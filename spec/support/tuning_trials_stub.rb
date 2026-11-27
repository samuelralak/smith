# frozen_string_literal: true

# A stand-in for the tuning loop's seam to the runner
# (Smith::Tuning::Evaluation) for specs of the loop: it answers from
# callables, records every request, and keeps the seam's contract ("a
# tuning trials seam", which Smith's own implementation passes too).
#
#   score:    ->(candidate, sample_id) { 0..1 }
#   feedback: ->(candidate, sample_id, component) { String or nil }, asked only with a component
#   reply:    ->(message) { {idea:, instruction:} }, the reflection's output; a raise is the model failing
#   admit:    how many calls it makes in all, trials and reflections, before the rest are refused, as a
#             ledger would (nil: no end)
#
# A key asked again for another candidate or other samples raises
# Smith::Evals::ResumeMismatch, as the runner does.
class TuningTrialsStub
  attr_reader :evaluations, :reflections

  def initialize(score:, feedback: ->(*) {}, reply: ->(_message) { { idea: nil, instruction: "Do it better." } },
                 admit: nil)
    @score = score
    @feedback = feedback
    @reply = reply
    @admit = admit
    @passes = {}
    @evaluations = []
    @reflections = []
  end

  def evaluate(candidate, sample_ids:, kind:, key:, component: nil)
    plan = [candidate.candidate_id, sample_ids]
    stored, asked = @passes[key]
    return stored if stored && asked == plan
    raise Smith::Evals::ResumeMismatch.new("key #{key} names another plan", fields: %w[candidate samples]) if stored

    @evaluations << { candidate:, sample_ids:, kind:, key:, component: }
    @passes[key] = [pass(candidate, sample_ids, key, component), plan]
    @passes[key].first
  end

  def reflect(message, trial_id:)
    @reflections << { message:, trial_id: }
    return refused(trial_id) if admitted(1).empty?

    output = @reply.call(message)
    Smith::Tuning::Reflection::Call.new(trial_id:, **attempted(message), output:, failure: nil, stop: nil)
  rescue StandardError => e
    failure = { "kind" => "aborted", "error_class" => e.class.name, "message" => e.message }
    Smith::Tuning::Reflection::Call.new(trial_id:, **attempted(message), output: nil, failure:, stop: nil)
  end

  private

  def pass(candidate, sample_ids, key, component)
    ran = admitted(sample_ids)
    Smith::Tuning::Evaluation::Pass.new(
      eval_run_id: Smith::Evals::Identity.eval_run_id(key:, scope: {}, suite: "tuning.stub"),
      samples: ran.to_h { [_1, sample(candidate, _1, component)] }, metric_calls: ran.size,
      provider_calls: ran.size, cost_nanos: 100 * ran.size, cost_complete: true,
      complete: ran.size == sample_ids.size, stop: (:cap_reached unless ran.size == sample_ids.size)
    )
  end

  # The calls the budget lets through, out of `wanted` (a count or a list).
  def admitted(wanted)
    wanted = Array.new(wanted) if wanted.is_a?(Integer)
    return wanted if @admit.nil?

    ran = wanted.first(@admit)
    @admit -= ran.size
    ran
  end

  def refused(trial_id)
    failure = { "kind" => "cap_reached", "error_class" => "Smith::BudgetExceeded", "message" => "the ledger refused" }
    Smith::Tuning::Reflection::Call.new(trial_id:, steps: [], usage: Smith::Evals::Spend.new.usage, output: nil,
                                        failure:, stop: :cap_reached)
  end

  # One attempt's step, and what it spent.
  def attempted(message)
    prompt = Smith::Tuning::Reflection::PROMPT
    step = TuningRecords.step(components: [{ "id" => prompt.component_id, "version" => prompt.version }],
                              messages: [{ "role" => "system", "text" => prompt.text },
                                         { "role" => "user", "text" => message }])
    spend = Smith::Evals::Spend.new.add(provider: step["provider"], model: step["model"], provider_calls: 1,
                                        tokens: step["tokens"], cost_nanos: step["cost_nanos"], cost_complete: true)
    { steps: [step], usage: spend.usage }
  end

  def sample(candidate, sample_id, component)
    score = @score.call(candidate, sample_id)
    return Smith::Tuning::Evaluation::Sample.new(score:, feedback: nil, steps: nil) unless component

    stamp = candidate.versions.map { |id, version| { "id" => id, "version" => version } }
    steps = stamp.map.with_index(1) { |entry, seq| TuningRecords.step(components: [entry], seq:) }
    Smith::Tuning::Evaluation::Sample.new(score:, feedback: @feedback.call(candidate, sample_id, component), steps:)
  end
end
