# frozen_string_literal: true

# Gives an agent class a model and a chat that answers `reply` without a
# provider call, for specs whose agents only need to run. An agent with no
# model fails when its step runs.
module AnsweringAgent
  def answering(agent, reply = "ok")
    agent.model("gpt-5-mini") unless agent.model_configured?
    agent.define_singleton_method(:chat) do |**|
      chat = Object.new
      chat.define_singleton_method(:add_message) { |_message| nil }
      chat.define_singleton_method(:with_schema) { |_schema| self }
      chat.define_singleton_method(:complete) { Struct.new(:content, :input_tokens, :output_tokens).new(reply, 1, 1) }
      chat
    end
    agent
  end
end

RSpec.configure { |config| config.include AnsweringAgent }
