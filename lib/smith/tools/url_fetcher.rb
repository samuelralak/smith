# frozen_string_literal: true

module Smith
  module Tools
    class UrlFetcher < Smith::Tool
      description "Fetch the content of a specific URL"
      category :data_access

      param :url, type: :string, required: true

      def perform(url:)
        raise NotImplementedError, "#{self.class} requires a host-app implementation"
      end
    end
  end
end
