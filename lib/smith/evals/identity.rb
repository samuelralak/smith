# frozen_string_literal: true

require "digest"
require "securerandom"
require_relative "../canonical_json"
require_relative "../scope"

module Smith
  module Evals
    # Experimental; the rules are frozen with slice 1a.2. Every id and
    # digest evals record (slice-1a design, 8.1 to 8.6), so any language
    # computes the same ones. Each digest is "sha256:" and 64 lowercase hex
    # over RFC 8785 canonical JSON, framed by a "name/N\n" prefix (eval run,
    # trial and group ids, and the sample ids digest, an array) or by a
    # format field inside the hashed object (versions, the measure, plan and
    # variant digests). Short ids keep 32 hex digits. Pure; each call is
    # linear in what it hashes (the sample ids digest O(n log n), as it
    # sorts).
    module Identity
      NAME = /\A[a-z][a-z0-9_.-]{0,127}\z/
      CONTENT_HASH = /\Asha256:[0-9a-f]{64}\z/
      EVAL_RUN_ID = /\Aer_[0-9a-f]{32}\z/
      CANDIDATE_ID = /\Acd_[0-9a-f]{32}\z/
      SAMPLE_ID = /\A[^\u0000-\u001f\u007f]{1,256}\z/
      SPLITS = %w[dev holdout calibration].freeze
      MAX_KEY_CHARACTERS = 256

      # The checks each id part passes before it is hashed.
      module Checks
        module_function

        def key!(key)
          return key if utf8?(key) && key.length.between?(1, MAX_KEY_CHARACTERS)

          raise ArgumentError, "an idempotency key is a String of 1 to #{MAX_KEY_CHARACTERS} characters"
        end

        def name!(name, what)
          return name if name.is_a?(String) && NAME.match?(name)

          raise ArgumentError, "a #{what} name matches #{NAME.source}"
        end

        def sample_id!(id)
          return id if utf8?(id) && SAMPLE_ID.match?(id)

          raise ArgumentError, "a sample id is a String of 1 to 256 characters, none of them a control character"
        end

        def candidate!(candidate)
          return candidate if CANDIDATE_ID.match?(candidate.to_s)

          raise ArgumentError, "a candidate id is cd_ and 32 hex digits"
        end

        def utf8?(text)
          text.is_a?(String) && ((text.encoding == Encoding::UTF_8 && text.valid_encoding?) || text.ascii_only?)
        end

        def content_hash!(value, what)
          return value if value.is_a?(String) && CONTENT_HASH.match?(value)

          raise ArgumentError, "#{what} is a digest: sha256: and 64 lowercase hex digits"
        end
      end
      private_constant :Checks

      class << self
        include Checks

        # "er_" and 32 hex digits from the key, scope and suite name, with the
        # variant digest for a linked run; random without a key.
        def eval_run_id(key:, scope:, suite:, variant: nil)
          scope = Smith::Scope.build(scope)
          name!(suite, "suite")
          return "er_#{SecureRandom.hex(16)}" if key.nil?

          value = { "key" => key!(key), "scope" => scope, "suite" => suite }
          value["variant"] = content_hash!(variant, "variant") unless variant.nil?
          "er_#{framed("smith.evals.eval_run/1", value)}"
        end

        # "eg_" and 32 hex digits: a group of linked runs (slice 1b).
        def group_id(key:, scope:, suite:)
          value = { "key" => key!(key), "scope" => Smith::Scope.build(scope), "suite" => name!(suite, "suite") }
          "eg_#{framed("smith.evals.group/1", value)}"
        end

        # "tr_" and 32 hex digits: the same across a relaunch.
        def trial_id(eval_run_id:, sample_id:, index:, candidate: nil)
          raise ArgumentError, "an eval run id is er_ and 32 hex digits" unless EVAL_RUN_ID.match?(eval_run_id.to_s)
          raise ArgumentError, "a trial index is an Integer of at least 0" unless index.is_a?(Integer) && index >= 0

          value = { "eval_run" => eval_run_id, "sample" => sample_id!(sample_id), "index" => index }
          value["candidate"] = candidate!(candidate) unless candidate.nil?
          "tr_#{framed("smith.evals.trial/1", value)}"
        end

        # 32 hex digits naming a tenant scope (store paths).
        def scope_digest(scope) = Smith::Scope.digest(scope)

        # The selected sample ids, sorted by UTF-16 code units, framed.
        def sample_ids_digest(ids)
          sorted = utf16_sort(Array(ids).map { sample_id!(_1) })
          sorted.each_cons(2) do |left, right|
            raise ArgumentError, "sample id #{left.inspect} is given twice" if left == right
          end
          "sha256:#{Digest::SHA256.hexdigest("smith.evals.sample_ids/1\n#{CanonicalJSON.generate(sorted)}")}"
        end

        # What a run with a known id or key must match to resume (5.6).
        def plan_digest(suite:, dataset:, samples:, split:, trials_per_sample:, candidate: nil, variant: nil)
          raise ArgumentError, "split is dev, holdout or calibration" unless SPLITS.include?(split.to_s)
          unless trials_per_sample.is_a?(Integer) && trials_per_sample.between?(1, 100)
            raise ArgumentError, "trials_per_sample is from 1 to 100"
          end

          digest("format" => "smith.evals.plan/1", "candidate" => candidate.nil? ? nil : candidate!(candidate),
                 "dataset" => content_hash!(dataset, "dataset"), "samples" => content_hash!(samples, "samples"),
                 "split" => split.to_s,
                 "suite" => content_hash!(suite, "suite"), "trials_per_sample" => trials_per_sample,
                 "variant" => variant.nil? ? nil : content_hash!(variant, "variant"))
        end

        # The suite manifest's version: without version, budget and
        # dataset.source (8.5).
        def suite_version(manifest)
          body = manifest.except("version", "budget")
          body["dataset"] = manifest.fetch("dataset").except("source")
          digest(body)
        rescue KeyError, NoMethodError
          raise ArgumentError, "a suite manifest is a Hash with String keys and a dataset"
        end

        # What a run measured, for comparisons (8.5): the infrastructure
        # errors among the trials' settings (they decide which failures count
        # against the rate), never the subject's identity, the variant,
        # gates, budget, error_retries, recording or dataset.source.
        def measure_digest(manifest, dataset:, samples:)
          selection, trials = manifest.values_at("selection", "trials")
          digest({ "format" => "smith.evals.measure/1", "dataset" => content_hash!(dataset, "dataset"),
                   "samples" => content_hash!(samples, "samples"), "split" => selection.fetch("split"),
                   "narrow" => selection.fetch("narrow") }.merge(measured(manifest, trials)))
        rescue KeyError, NoMethodError
          raise ArgumentError, "a suite manifest is a Hash with String keys, a selection, a subject and trials"
        end

        # A model variant (slice 1b): its llm block, never its label.
        def variant_digest(llm)
          raise ArgumentError, "a variant's llm is a Hash" unless llm.is_a?(Hash)

          digest("format" => "smith.evals.variant/1", "llm" => llm)
        end

        # The dataset version from its four part hashes (8.2).
        def dataset_version(hashes)
          parts = %w[inputs labels splits metadata].to_h { [_1, content_hash!(hashes[_1] || hashes[_1.to_sym], _1)] }
          digest({ "format" => "smith.evals.dataset/1" }.merge(parts))
        end

        # Strings in UTF-16 code unit order (UTF-16BE bytes compare so).
        def utf16_sort(strings)
          strings.sort_by { _1.encode(Encoding::UTF_16BE).b }
        rescue EncodingError
          raise ArgumentError, "ids are Strings of UTF-8"
        end

        # "sha256:" and the hex SHA-256 of a value's canonical JSON.
        def digest(value) = "sha256:#{Digest::SHA256.hexdigest(CanonicalJSON.generate(value))}"

        private

        def framed(frame, value) = Digest::SHA256.hexdigest("#{frame}\n#{CanonicalJSON.generate(value)}")[0, 32]

        def measured(manifest, trials)
          { "subject" => measured_subject(manifest.fetch("subject")),
            "trials" => { "per_sample" => trials.fetch("per_sample"), "reduce" => trials.fetch("reduce"),
                          "infrastructure_errors" => trials.fetch("infrastructure_errors") },
            "scorers" => manifest.fetch("scorers"), "statistics" => { "level" => manifest.dig("statistics", "level") },
            "labels" => manifest["labels"] }
        end

        # The subject's input mapping, keep and until: a workflow's mapping
        # is code, so its declared version stands in; a definition's is data.
        def measured_subject(subject)
          mapping = { "workflow" => "version", "definition" => "input" }.fetch(subject.fetch("kind")) do
            raise ArgumentError, "a subject's kind is workflow or definition"
          end
          { "kind" => subject["kind"], mapping => subject.fetch(mapping), "keep" => subject.fetch("keep"),
            "until" => subject.fetch("until") }
        end
      end
    end
  end
end
