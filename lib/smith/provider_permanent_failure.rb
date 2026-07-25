# frozen_string_literal: true

require_relative "error"

module Smith
  class ProviderPermanentFailure < Error
    attr_reader :provider, :model_id, :source_error_class

    def initialize(message, provider:, model_id:, source_error_class:)
      @provider = provider&.to_sym
      @model_id = model_id.to_s.dup.freeze
      @source_error_class = source_error_class.to_s.dup.freeze
      super(message)
    end
  end
end
