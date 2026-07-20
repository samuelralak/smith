# frozen_string_literal: true

class SpecRubyLLMChat < ActiveRecord::Base
  self.table_name = "spec_ruby_llm_chats"

  acts_as_chat messages: :messages,
               message_class: "SpecRubyLLMMessage",
               messages_foreign_key: :chat_id,
               model: :model,
               model_class: "SpecRubyLLMModel",
               model_foreign_key: :model_id
end
