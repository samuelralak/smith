# frozen_string_literal: true

module Smith
  module Evals
    class DatasetManifest
      # Internal. The manifest format's rules (contracts'
      # dataset-manifest.schema.json), checked by hand so no schema gem is
      # needed at runtime: the first problem as "/field: problem", or nil.
      # Unknown fields are left alone.
      module Format
        TIMESTAMP = /\A\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(\.\d{1,6})?Z\z/
        # A name in the folder: no separator, no control character, not . or ..
        FILE_NAME = %r{\A(?!\.\.?\z)[^/\\\u0000-\u001f\u007f]{1,256}\z}
        SPLITS = %w[dev holdout calibration].freeze
        TEXT = ->(pattern) { ->(value) { value.is_a?(String) && pattern.match?(value) } }
        HEADER = {
          "format" => [FORMAT.method(:==), "is #{FORMAT}"],
          "format_version" => [1.method(:==), "is 1"],
          "name" => [TEXT.call(Identity::NAME), "is a name (#{Identity::NAME.source})"],
          "version" => [TEXT.call(Identity::CONTENT_HASH), "is a digest"],
          "created_at" => [TEXT.call(TIMESTAMP), "is a UTC time (RFC 3339 with a Z)"],
          "samples_file" => [TEXT.call(FILE_NAME), "is a file name in the dataset's folder"],
          "samples_format" => [SAMPLES_FORMAT.method(:==), "is #{SAMPLES_FORMAT}"],
          "previous_version" => [->(value) { value.nil? || TEXT.call(Identity::CONTENT_HASH).call(value) },
                                 "is null or a digest"]
        }.freeze
        RESPLIT = %w[at by previous_version previous_split_rule].freeze
        COUNTS = { "split_counts" => SPLITS, "labels" => Contents::LABEL_KINDS,
                   "retention" => %w[expiring kept] }.freeze

        module_function

        def problem(value)
          return "/: a manifest is a JSON object" unless value.is_a?(Hash)

          missing = FIELDS.find { !value.key?(_1) }
          return "/#{missing}: is required" if missing

          header(value) || contents(value) || counts(value) || resplits(value["resplits"])
        end

        def header(value)
          found = HEADER.find { |field, (fits, _)| !fits.call(value[field]) }
          return "/#{found[0]}: #{found[1][1]}" if found

          actor(value["created_by"])
        end

        def contents(value)
          return "/hashes: holds the four part digests" unless map?(value["hashes"], PARTS) { digest?(_1) }
          unless map?(value["split_assignment"], SPLITS) { _1.is_a?(Array) }
            return "/split_assignment: lists the ids of each split"
          end

          rule(value["split_rule"])
        end

        def counts(value)
          found = COUNTS.find { |field, keys| !map?(value[field], keys) { count?(_1) } }
          return "/#{found[0]}: holds a count for each of #{found[1].join(", ")}" if found

          found = %w[hand_assigned clusters].find { !count?(value[_1]) }
          return "/#{found}: is an Integer of at least 0" if found

          count = value["sample_count"]
          "/sample_count: is an Integer of at least 1" unless count?(count) && count >= 1
        end

        def actor(value, path = "/created_by")
          Actor.from_h(value)
          nil
        rescue ArgumentError
          "#{path}: is null or an actor {kind, id}"
        end

        # Each re-split, oldest first: when, by whom, and the version and
        # rule it replaced.
        def resplits(value)
          return "/resplits: is an Array of re-splits" unless value.is_a?(Array)

          value.each_with_index do |entry, index|
            problem = resplit(entry, "/resplits/#{index}")
            return problem if problem
          end
          nil
        end

        def resplit(entry, path)
          unless entry.is_a?(Hash) && RESPLIT.all? { entry.key?(_1) }
            return "#{path}: is an object {at, by, previous_version, previous_split_rule}"
          end

          return "#{path}/at: is a UTC time (RFC 3339 with a Z)" unless TEXT.call(TIMESTAMP).call(entry["at"])
          return "#{path}/previous_version: is a digest" unless digest?(entry["previous_version"])

          actor(entry["by"], "#{path}/by") || rule(entry["previous_split_rule"], "#{path}/previous_split_rule")
        end

        def rule(value, path = "/split_rule")
          SplitRule.from_h(value)
          nil
        rescue ArgumentError => e
          "#{path}: #{e.message}"
        end

        def map?(value, keys, &)
          value.is_a?(Hash) && keys.all? { value.key?(_1) && yield(value[_1]) }
        end

        def digest?(value) = value.is_a?(String) && Identity::CONTENT_HASH.match?(value)
        def count?(value) = value.is_a?(Integer) && value >= 0
      end
    end
  end
end
