# frozen_string_literal: true

module Smith
  module Tools
    class WebSearch < Smith::Tool
      description "Search the web for current information on a topic"
      category :data_access

      param :query, type: :string, required: true
      param :max_results, type: :integer, required: false

      def perform(query:, max_results: 5)
        raise NotImplementedError, "#{self.class} requires a host-app implementation"
      end
    end
  end
end
