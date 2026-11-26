# frozen_string_literal: true

require_relative "errors"
require_relative "identity"
require_relative "../json_value"

module Smith
  module Evals
    # Experimental; the line format (smith.evals.sample/1) is frozen with
    # slice 1a.2. One sample as a scorer reads it (slice-1a design, 4.2):
    # its line's values with symbol keys, deeply frozen, and the split the
    # dataset assigned. `to_h` is the line as read (String keys), which the
    # dataset's hashes are computed from; a null top-level field is an
    # absent one. The dataset version covers id, input, expected, label,
    # the split, cluster, tags, synthetic, source and metadata only: a
    # scorer that reads another field (an operational one, or one this
    # format does not know) measures something no version tracks.
    class Sample
      # Read as the line holds them.
      PLAIN = %w[id cluster synthetic erasure_key expires_at keep added_at].freeze

      attr_reader :input, :expected, :split, :label, :metadata, :source

      # A line that is not in the format raises DatasetInvalid, its message
      # "where: /path: problem", naming no value of the line.
      def self.check!(line, where:)
        problem = Line.problem(line)
        raise DatasetInvalid, "#{where}: #{problem}" if problem
      end

      def initialize(line, split:)
        @line = JSONValue.frozen(line)
        @split = split.to_sym
        @input, @expected, @label, @source = @line.values_at("input", "expected", "label", "source")
                                                  .map { JSONValue.symbolized(_1) }
        @metadata = JSONValue.symbolized(@line["metadata"] || {})
        freeze
      end

      PLAIN.each { |field| define_method(field) { @line[field] } }

      # The split the line set by hand (it won over the rule), or nil.
      def hand_split = @line["split"]&.to_sym
      def tags = @line["tags"] || [].freeze
      def to_h = @line

      # The line format's rules (contracts' sample.schema.json), checked by
      # hand so no schema gem is needed at runtime. Unknown fields are left
      # alone: readers ignore what they do not know.
      module Line
        TIMESTAMP = /\A\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(\.\d{1,6})?Z\z/
        TAG = /\A[a-z0-9][a-z0-9_.:-]{0,63}\z/
        CODE = /\A[a-z][a-z0-9_]{0,63}\z/
        LABEL_KINDS = %w[human ai adjudicated disputed].freeze
        SPLITS = %w[dev holdout calibration].freeze
        TIME = "is null or a UTC time (RFC 3339 with a Z)"
        FLAG = "is null, true or false"
        # Each optional field's rule, checked when it is not null.
        FIELDS = {
          "split" => [->(v) { SPLITS.include?(v) }, "is null, dev, holdout or calibration"],
          "cluster" => [->(v) { text?(v, 256, minimum: 1) }, "is null or a String of 1 to 256 characters"],
          "synthetic" => [->(v) { [true, false].include?(v) }, FLAG],
          "metadata" => [->(v) { v.is_a?(Hash) }, "is null or a JSON object"],
          "erasure_key" => [->(v) { text?(v, 256) }, "is null or a String of at most 256 characters"],
          "expires_at" => [->(v) { time?(v) }, TIME],
          "keep" => [->(v) { [true, false].include?(v) }, FLAG],
          "added_at" => [->(v) { time?(v) }, TIME]
        }.freeze
        # Inside label and source a field is a value or absent, never null.
        LABEL_FIELDS = {
          "by" => [->(v) { text?(v, 256) }, "is a String of at most 256 characters"],
          "model" => [->(v) { text?(v, 256) }, "is a String of at most 256 characters"],
          "judge_version" => [->(v) { text?(v, 128) }, "is a String of at most 128 characters"],
          "settled_by" => [->(v) { text?(v, 256) }, "is a String of at most 256 characters"],
          "raters" => [->(v) { v.is_a?(Array) && v.all? { text?(_1, 256) } }, "is an Array of Strings"],
          "at" => [->(v) { time?(v) }, "is a UTC time (RFC 3339 with a Z)"]
        }.freeze
        SOURCE_FIELDS = {
          "run_key" => [->(v) { text?(v, 256) }, "is a String of at most 256 characters"],
          "step" => [->(v) { text?(v, 256) }, "is a String of at most 256 characters"],
          "at" => [->(v) { time?(v) }, "is a UTC time (RFC 3339 with a Z)"]
        }.freeze

        module_function

        def problem(line)
          return "a sample is a JSON object" unless line.is_a?(Hash)

          required(line) || first(line, FIELDS, "", nullable: true) || tags(line["tags"]) || label(line["label"]) ||
            source(line["source"]) || retention(line)
        end

        def required(line)
          return "/id: is required" unless line.key?("id")
          return "/id: is a String of 1 to 256 characters, none of them a control character" unless id?(line["id"])

          "/input: is required" unless line.key?("input")
        end

        # The first field present (and not null, when null is absent) that
        # breaks its rule.
        def first(object, rules, path, nullable: false)
          found = rules.find do |name, (fits, _)|
            object.key?(name) && !(nullable && object[name].nil?) && !fits.call(object[name])
          end
          found && "#{path}/#{found[0]}: #{found[1][1]}"
        end

        def tags(value)
          return if value.nil?
          return "/tags: is null or an Array of tags" unless value.is_a?(Array)

          index = value.index { !(text?(_1, 64) && TAG.match?(_1)) }
          return "/tags/#{index}: is a tag (#{TAG.source})" if index

          "/tags: holds a tag twice" unless value.uniq.size == value.size
        end

        def label(value)
          return if value.nil?
          return "/label: is null or a JSON object" unless value.is_a?(Hash)
          return "/label/kind: is required" unless value.key?("kind")
          return "/label/kind: is human, ai, adjudicated or disputed" unless LABEL_KINDS.include?(value["kind"])

          first(value, LABEL_FIELDS, "/label")
        end

        def source(value)
          return if value.nil?
          return "/source: is null or a JSON object" unless value.is_a?(Hash)
          return "/source/kind: is required" unless value.key?("kind")

          kind = value["kind"]
          return "/source/kind: is a code (#{CODE.source})" unless text?(kind, 64) && CODE.match?(kind)

          first(value, SOURCE_FIELDS, "/source")
        end

        # A sample made from a production run must expire or be kept on purpose.
        def retention(line)
          return unless line.dig("source", "kind") == "production_run"
          return if !line["expires_at"].nil? || line["keep"] == true

          "/source: a production_run sample needs expires_at or keep: true"
        end

        def id?(value) = text?(value, 256, minimum: 1) && Identity::SAMPLE_ID.match?(value)
        def text?(value, limit, minimum: 0) = JSONValue.utf8?(value) && value.length.between?(minimum, limit)
        def time?(value) = value.is_a?(String) && value.ascii_only? && TIMESTAMP.match?(value)
      end
      private_constant :Line
    end
  end
end
