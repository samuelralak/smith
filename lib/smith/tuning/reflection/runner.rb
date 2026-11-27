# frozen_string_literal: true

require "digest"

module Smith
  module Tuning
    module Reflection
      # Experimental. An iteration's one reflection call (slice 5a design,
      # section 1, row 5), made as a recorded trial: a one-step workflow
      # whose agent is built from the run's `reflection:` setting, run
      # through Smith::Evals::Drivers::InProcess with the trial id the loop
      # gives, under a recorder whose message and step bounds are raised to
      # their ceilings, so the prompt and reply are kept whole. Its agent
      # sends Reflection::PROMPT (a named prompt, so its version is
      # stamped), the setting's model on its provider as named, its
      # temperature, its output limit under the provider's own name, its
      # thinking only when set, and holds its reply to one call (no output
      # repair); the workflow holds that call on the setting's budget
      # ledger. A transient or transport failure of the provider (the eval
      # runner's provider_unavailable) is tried again while the setting's
      # attempts last, after the driver's backoff (Evals::Driver#backoff,
      # the runner's rule); nothing else is, a reply that does not fit and
      # a ledger refusal included. Each attempt is under the one
      # recorder, so the call's steps and usage are every attempt's. A call
      # the ledger refuses stops the tuning run at the cap (`stop`
      # :cap_reached); an error that stops every run stops it with its
      # reason code; any other failure ends only its iteration. A failure
      # names its reason code and error class, never the error's own words.
      #
      # One agent class for each model and settings, in this process,
      # named for them: `Runner.agent(setting)` is it, which
      # Smith::Testing stubs answer.
      class Runner
        RECORDING = Evals::Configuration.recording(
          { content: true }.merge(Evals::Configuration::RECORDING_CEILINGS.slice(:max_message_bytes, :max_step_bytes))
        )
        # The one reading tried again.
        UNAVAILABLE = "provider_unavailable"
        private_constant :RECORDING, :UNAVAILABLE

        @agents = {}
        @lock = Mutex.new

        # The reply's shape.
        class Shape
          def to_json_schema
            fields = { idea: { type: "string" }, instruction: { type: "string" } }
            { name: "reflection", schema: { type: "object", required: %w[idea instruction], properties: fields,
                                            additionalProperties: false } }
          end
        end
        private_constant :Shape

        # The agent for a reflection model (a Settings::ReflectionModel, or
        # the `reflection:` setting as given).
        def self.agent(model)
          model = Settings::ReflectionModel.build(model) if model.is_a?(Hash)
          sent = model.recorded.slice("model", "provider", "settings")
          name = :"smith_tuning_reflect_#{Digest::SHA256.hexdigest(CanonicalJSON.generate(sent))[0, 16]}"
          # Registered again each time: a registry cleared since (a host's
          # reload) gets it back; the same class again changes nothing.
          @lock.synchronize { (@agents[name] ||= built(model)).register_as(name) }
        end

        def self.built(setting)
          agent = Class.new(Smith::Agent) do
            model setting.model, provider: setting.provider.to_sym, assume_model_exists: true
            output_schema Shape.new
            output_repairs 0
            instructions PROMPT
          end
          sends(agent, setting)
        end

        # What the setting sends beside its model, only what it sets.
        def self.sends(agent, setting)
          agent.temperature(setting.temperature) unless setting.temperature.nil?
          agent.thinking(**setting.thinking.transform_keys(&:to_sym)) if setting.thinking
          tokens = setting.max_output_tokens
          limit = tokens && Providers::OutputLimit.params(setting.provider, {}, tokens)
          agent.params(**limit) if limit
          agent
        end
        private_class_method :built, :sends

        def initialize(model, scope:)
          @scope = Smith::Scope.build(scope)
          @attempts = model.attempts
          @driver = Evals::Drivers::InProcess.new
          @subject = Evals::Subject.new(workflow: workflow(self.class.agent(model).register_as, model.budget_ledger),
                                        input: ->(sample) { { message: sample.input } }, keep: %i[reply])
        end

        # The call, as a Reflection::Call.
        def call(message, trial_id:)
          sample = Evals::Sample.new({ "id" => "reflection", "input" => message }, split: :dev)
          recorder = Evals::Recorder.new(trial_id, recording: RECORDING)
          result, outcome = Evals::Recording.attach(recorder) { attempted(sample, trial_id, recorder) }
          answered(trial_id, result, outcome, recorder)
        end

        private

        # The last attempt's result and outcome: another follows a provider
        # that was unavailable while attempts are left, after the runner's
        # backoff.
        def attempted(sample, trial_id, recorder)
          (1..@attempts).each do |attempt|
            spec = Evals::TrialSpec.new(trial_id:, eval_run_id: nil, scope: @scope, sample:, trial_index: 0,
                                        candidate: nil, subject: @subject, variant: nil, attempt:, seed: 0)
            result = @driver.run(spec, spec.context)
            outcome = Evals::Outcomes.classify(result, steps: recorder.steps)
            return [result, outcome] if attempt == @attempts || outcome.reason&.fetch("code") != UNAVAILABLE

            wait = @driver.backoff(attempt)
            sleep(wait) if wait.positive?
          end
        end

        def answered(trial_id, result, outcome, recorder)
          spent = { trial_id:, steps: recorder.steps, usage: recorder.usage }
          return Call.new(**spent, output: result.state&.fetch(:reply, nil), failure: nil, stop: nil) if
            outcome.outcome == :answered

          Call.new(**spent, output: nil, failure: failure(result, outcome), stop: stop(outcome))
        end

        def failure(result, outcome)
          reason = outcome.reason
          error_class = result.error ? DiagnosticText.error_class_name(result.error) : "none"
          { "kind" => reason["code"], "error_class" => error_class, "message" => reason["detail"] }
        end

        def stop(outcome)
          code = outcome.reason["code"]
          return :cap_reached if code == "ledger_refused"

          code.to_sym if outcome.stops_run
        end

        def workflow(agent, ledger)
          Class.new(Smith::Workflow) do
            budget_ledger { |_scope| ledger } if ledger
            initial_state :asked
            state :answered
            state :failed
            transition :reflect, from: :asked, to: :answered do
              execute agent, input: ->(context) { [{ role: :user, content: context[:message] }] }, output_to: :reply
              on_failure :fail
            end
          end
        end
      end
    end
  end
end
