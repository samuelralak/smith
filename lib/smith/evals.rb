# frozen_string_literal: true

require_relative "../smith"
require_relative "evals/statistics"
require_relative "evals/errors"
require_relative "evals/actor"
require_relative "evals/configuration"
require_relative "evals/identity"
require_relative "evals/split_rule"
require_relative "evals/sample"
require_relative "evals/dataset_manifest"
require_relative "evals/file_dataset"
require_relative "evals/dataset"
require_relative "evals/score"
require_relative "evals/reducers"
require_relative "evals/scorer"
require_relative "evals/subject"
require_relative "evals/suite_manifest"
require_relative "evals/suite"

module Smith
  # Experimental. Evals: datasets, scorers and suites, loaded only by
  # `require "smith/evals"` (slice-1a design). Nothing here is loaded by
  # `require "smith"`, and in this slice nothing is installed into the
  # core: the recorder joins in slice 1a.4.
  module Evals
    EXPERIMENTAL = true
  end
end
