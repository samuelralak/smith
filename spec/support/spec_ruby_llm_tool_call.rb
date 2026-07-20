# frozen_string_literal: true

class SpecRubyLLMToolCall < ActiveRecord::Base
  self.table_name = "spec_ruby_llm_tool_calls"

  acts_as_tool_call message: :message,
                    message_class: "SpecRubyLLMMessage",
                    message_foreign_key: :message_id,
                    result: :result,
                    result_class: "SpecRubyLLMMessage",
                    result_foreign_key: :tool_call_id
end
