# frozen_string_literal: true

require "digest"

module Smith
  module Evals
    class DatasetManifest
      # Internal. What a dataset's samples give its manifest (slice-1a design, 8.2 and
      # 8.3): each line checked, the lines sorted by id in UTF-16 code
      # units, each split assigned (a hand-set split wins over the rule),
      # the four part hashes and the counts. Each part hash is SHA-256 over
      # one line per sample: the canonical JSON of the part's object, a
      # null or absent field left out, then a line feed. Not hashed:
      # erasure_key, expires_at, keep and added_at (operational).
      #
      # O(S + n log n) time for S sample bytes and n samples; O(S) space.
      class Contents
        MAX_SAMPLES = 1_000_000
        LABEL_KINDS = %w[human ai adjudicated disputed none].freeze

        attr_reader :rule, :entries, :hashes, :version, :assignment

        # Contents of sample Hashes from a host, each taken in its JSON form
        # (String keys) and named "sample N" in messages.
        def self.from_lines(lines, rule)
          pairs = lines.each_with_index.lazy.map do |line, index|
            [JSONValue.normalized(line), "sample #{index + 1}"]
          rescue CanonicalJSON::Error => e
            raise DatasetInvalid, "sample #{index + 1}: #{e.message}"
          end
          new(pairs, rule)
        end

        # pairs: [line, where] for each sample, where naming it in messages
        # ("samples.jsonl line 12", "sample 12").
        def initialize(pairs, rule)
          @rule = rule
          @entries = sorted(checked(pairs)).freeze
          raise DatasetInvalid, "the dataset holds no sample" if @entries.empty?

          @hashes = part_hashes.freeze
          @version = Identity.dataset_version(@hashes)
          @assignment = %w[dev holdout calibration].to_h { |split| [split, ids_in(split).freeze] }.freeze
          freeze
        end

        # The manifest fields the samples decide, which loading checks.
        def derived
          { "version" => version, "sample_count" => entries.size, "split_assignment" => assignment,
            "split_counts" => assignment.transform_values(&:size),
            "hand_assigned" => entries.count { _1[:line]["split"] }, "clusters" => cluster_count,
            "labels" => label_counts, "retention" => retention }
        end

        # Every manifest field the samples and the rule give.
        def fields = derived.merge("hashes" => hashes, "split_rule" => rule.to_h)

        # Clusters a hand-set split made straddle splits (frozen).
        def warnings
          entries.select { _1[:line]["cluster"] }.group_by { _1[:line]["cluster"] }.filter_map do |cluster, members|
            splits = members.map { _1[:split] }.uniq.sort.freeze
            { code: "cluster_straddles_splits", cluster:, splits: }.freeze if splits.size > 1
          end.freeze
        end

        private

        def checked(pairs)
          list = []
          pairs.each do |line, where|
            raise DatasetInvalid, "a dataset holds at most #{MAX_SAMPLES} samples" if list.size >= MAX_SAMPLES

            Sample.check!(line, where:)
            list << entry(line, where)
          end
          list
        end

        # The sample's part lines, canonical now so a value with no
        # canonical form is refused at its line.
        def entry(line, where)
          id = line["id"]
          split = line["split"] || rule.assign(id:, cluster: line["cluster"])
          { id:, line:, where:, split:, key: id.encode(Encoding::UTF_16BE).b, parts: part_lines(line, split) }
        rescue CanonicalJSON::Error => e
          raise DatasetInvalid, "#{where}: #{e.message}"
        end

        # inputs, labels, splits, metadata: each object's canonical JSON, a
        # null or absent field left out (the input is required, so kept).
        def part_lines(line, split)
          id = line["id"]
          [{ "id" => id, "input" => line["input"] }, present(line, "expected", "label"),
           { "id" => id, "split" => split }, present(line, "cluster", "tags", "synthetic", "source", "metadata")]
            .map { CanonicalJSON.generate(_1) }
        end

        def present(line, *fields) = { "id" => line["id"] }.merge(line.slice(*fields).compact)

        def sorted(list)
          list.sort_by! { _1[:key] }
          list.each_cons(2) do |left, right|
            next unless left[:id] == right[:id]

            raise DatasetInvalid, "sample id #{left[:id].inspect} appears twice (#{left[:where]}, #{right[:where]})"
          end
          list
        end

        def part_hashes
          digests = PARTS.map { Digest::SHA256.new }
          entries.each { |entry| entry[:parts].each_with_index { |text, index| digests[index] << text << "\n" } }
          PARTS.zip(digests).to_h { |part, digest| [part, "sha256:#{digest.hexdigest}"] }
        end

        # Distinct cluster keys; a sample without one is its own.
        def cluster_count
          entries.to_set { |entry| (cluster = entry[:line]["cluster"]) ? [:cluster, cluster] : [:id, entry[:id]] }.size
        end

        def ids_in(split) = entries.filter_map { _1[:id] if _1[:split] == split }

        def label_counts
          counts = LABEL_KINDS.to_h { [_1, 0] }
          entries.each { counts[_1[:line].dig("label", "kind") || "none"] += 1 }
          counts
        end

        def retention
          { "expiring" => entries.count { _1[:line]["expires_at"] },
            "kept" => entries.count { _1[:line]["keep"] == true } }
        end
      end
    end
  end
end
