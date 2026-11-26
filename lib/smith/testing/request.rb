# frozen_string_literal: true

require "json"

module Smith
  module Testing
    # One request a stubbed agent makes, as a stub's callable is handed it
    # (`stub_agent(agent, outputs: ->(request) { ... })`), so a stub answers
    # by what was asked rather than by the order requests come in. Frozen.
    #
    # agent: the registered name (or class name) the stub was made for;
    # number: this stub's request count, from 1; round: 1 for a call's first
    # request, plus the assistant replies after its last user message (a
    # tool loop's second request is round 2); model and provider: the chat's;
    # system: its system messages' text, joined by a blank line (nil when it
    # has none); messages: the chat's messages in Smith's plain transcript
    # form (AttemptObservation::Transcript), uncut; last_user: the last user
    # message's text, or nil; tools: the names of the tools it offers;
    # schema: its output schema as JSON, or nil. Built from the chat's public
    # readers; O(M) for its M messages.
    Request = Data.define(:agent, :number, :round, :model, :provider, :system, :messages, :last_user, :tools,
                          :schema) do
      def self.from_chat(chat, agent:, number:)
        messages = AttemptObservation::Transcript.messages(chat.messages)
        new(agent:, number:, round: round(messages), **asked(chat), messages:,
            system: texts(messages, "system").join("\n\n").then { _1.empty? ? nil : _1 },
            last_user: texts(messages, "user").last)
      end

      # The chat's model, provider, tools and schema.
      def self.asked(chat)
        { model: chat.model.id, provider: chat.model.provider.to_s, tools: chat.tools.keys.map(&:to_s).freeze,
          schema: chat.schema && JSON.parse(JSON.generate(chat.schema)).freeze }
      end

      def self.round(messages)
        last_user = messages.rindex { _1["role"] == "user" } || -1
        1 + messages.drop(last_user + 1).count { _1["role"] == "assistant" }
      end

      def self.texts(messages, role) = messages.select { _1["role"] == role }.filter_map { _1["text"] }

      private_class_method :asked, :round, :texts
    end
  end
end
