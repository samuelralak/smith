# frozen_string_literal: true

class SpecRubyLLMMessage < ActiveRecord::Base
  self.table_name = "spec_ruby_llm_messages"

  acts_as_message chat: :chat,
                  chat_class: "SpecRubyLLMChat",
                  chat_foreign_key: :chat_id,
                  tool_calls: :tool_calls,
                  tool_call_class: "SpecRubyLLMToolCall",
                  tool_calls_foreign_key: :message_id,
                  model: :model,
                  model_class: "SpecRubyLLMModel",
                  model_foreign_key: :model_id
end
