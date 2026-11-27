# frozen_string_literal: true

require_relative "../../content_identity"
require_relative "../identity"

module Smith
  module Evals
    class Plan
      # Internal. The checks slice 5a's arguments to a run pass (slice 5a
      # design, section 2), each refusing with ArgumentError: `samples`, ids
      # the suite's selection holds, at least one, none twice; `trials`, 1
      # to 100; `kind`, one this release runs; and `candidate`, which
      # answers `reference`, the header's candidate ({candidate_id,
      # tuning_run_id, components: [{id, version}]}), and `texts`, a text
      # for each component the reference names, each the version it names,
      # so the header never names a text the run did not send. O(N) in the
      # samples, O(B) in the texts' bytes.
      module Checks
        KINDS = %w[eval tuning_minibatch tuning_validation].freeze

        module_function

        def kind!(kind)
          return kind.to_s.freeze if (kind.is_a?(String) || kind.is_a?(Symbol)) && KINDS.include?(kind.to_s)

          raise ArgumentError, "kind is eval, tuning_minibatch or tuning_validation"
        end

        def trials!(trials)
          return trials if trials.is_a?(Integer) && trials.between?(1, 100)

          raise ArgumentError, "trials is an Integer from 1 to 100"
        end

        # The selected samples with the ids given, in the selection's order.
        def narrowed(samples, ids)
          wanted = ids!(ids)
          missing = wanted - samples.to_set(&:id)
          raise ArgumentError, "samples names #{missing.first}, which the suite does not select" if missing.any?

          samples.select { wanted.include?(_1.id) }.freeze
        end

        def ids!(ids)
          raise ArgumentError, "samples names at least one sample" unless ids.is_a?(Array) && !ids.empty?

          twice = ids.tally.find { |_id, count| count > 1 }&.first
          raise ArgumentError, "samples names #{twice} twice" if twice

          ids.to_set
        end

        def candidate!(candidate)
          return if candidate.nil?
          unless candidate.respond_to?(:reference) && candidate.respond_to?(:texts)
            raise ArgumentError, "a candidate answers reference and texts"
          end

          texts!(candidate.texts, versions(candidate.reference))
          candidate
        end

        def versions(reference)
          unless reference.is_a?(Hash) && Identity::CANDIDATE_ID.match?(reference["candidate_id"].to_s) &&
                 Identity::TUNING_RUN_ID.match?(reference["tuning_run_id"].to_s) && components?(reference["components"])
            raise ArgumentError, "a candidate's reference names its candidate_id, tuning_run_id and components"
          end

          reference["components"].to_h { [_1["id"], _1["version"]] }
        end

        def components?(components)
          components.is_a?(Array) && !components.empty? && components.all? do |entry|
            entry.is_a?(Hash) && entry["id"].is_a?(String) && ContentIdentity::DIGEST.match?(entry["version"].to_s)
          end
        end

        def texts!(texts, versions)
          unless texts.is_a?(Hash) && texts.keys.sort == versions.keys.sort && texts.values.all?(String)
            raise ArgumentError, "a candidate's texts are a text for each component its reference names"
          end

          wrong = versions.find { |id, version| ContentIdentity.digest(texts[id]) != version }&.first
          raise ArgumentError, "the candidate's text for #{wrong} is not the version its reference names" if wrong
        end
      end
      private_constant :Checks
    end
  end
end
