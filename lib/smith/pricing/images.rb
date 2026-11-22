# frozen_string_literal: true

module Smith
  module Pricing
    # A model's image tokens, priced apart from its text (Pricing.compute_cost)
    # and held at what its catalog entry says an image writes
    # (Pricing.image_output_tokens).
    module Images
      module_function

      # The image parts are inside the plain counts (`counts`: input, output),
      # already priced at the plain rates: each adds what its image rate asks
      # beyond its plain one, and never more of them than the plain count holds.
      def priced(rates, counts, image_input_tokens, image_output_tokens)
        ([image_input_tokens, counts[0]].min * ((rates[:image_input] || rates[:input]) - rates[:input])) +
          ([image_output_tokens, counts[1]].min * ((rates[:image_output] || rates[:output]) - rates[:output]))
      end

      # What one image of `size` and `quality` writes, as the entry's
      # `image_output_tokens` says; nil when it says nothing.
      def output_tokens(entry, size, quality)
        count = [:image_output_tokens, size, quality].reduce(entry) do |level, key|
          Pricing.__send__(:value_at, level, key.to_s.to_sym) if level.is_a?(Hash)
        end
        count if count.is_a?(Integer) && count.positive?
      end
    end
  end
end
