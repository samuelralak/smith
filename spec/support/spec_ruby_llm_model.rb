# frozen_string_literal: true

class SpecRubyLLMModel < ActiveRecord::Base
  self.table_name = "spec_ruby_llm_models"

  acts_as_model chats: :chats,
                chat_class: "SpecRubyLLMChat",
                chats_foreign_key: :model_id
end
