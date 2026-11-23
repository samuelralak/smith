# frozen_string_literal: true

require "digest"

module CoreInvisibility
  # Builders for the scenarios' agents, workflows, tools and schemas, each
  # a named top-level class, as a host's would be.
  module Define
    module_function

    # `cap`: its output cap, none when nil; `listed`: its model looked up in
    # RubyLLM's list rather than assumed to exist.
    def agent(name, register, model_id: "claude-sonnet-5-5", provider: :anthropic, prompt: nil, cap: 500,
              listed: false, &body)
      klass = Object.const_set(name, Class.new(Smith::Agent))
      klass.class_exec do
        register_as register
        model model_id, provider:, assume_model_exists: !listed
        params max_tokens: cap if cap
        instructions { |_context| prompt } if prompt
      end
      klass.class_exec(&body) if body
      klass
    end

    def workflow(name, &)
      klass = Object.const_set(name, Class.new(Smith::Workflow))
      klass.include(Hosts::Stepped)
      klass.class_exec(&)
      klass
    end

    # A tool taking one query, answering with `answer.call(query)`.
    def tool(name, answer)
      Object.const_set(name, Class.new(Smith::Tool) do
        description "Looks a place up."
        param :query, type: :string, required: true
        define_method(:perform) { |query:| answer.call(query) }
      end)
    end

    # A schema RubyLLM sends (to_json_schema) and Smith's orchestrator
    # checks (required_keys, read with the keys the output has: Strings as
    # parsed, Symbols once an agent symbolizes them).
    def schema(name, properties, required: properties.keys, string_keys: false)
      body = { type: "object", required: required.map(&:to_s), properties: }
      label = name.downcase
      keys = required.map { string_keys ? _1.to_s : _1.to_sym }
      Object.const_set(name, Class.new do
        define_singleton_method(:required_keys) { keys }
        define_method(:to_json_schema) { { name: label, schema: body } }
      end)
    end

    # A reply chosen by the request's own bytes, so branches that run in any
    # order get the same answers.
    def by_request(request)
      { json: Replies.message("Noted #{Digest::SHA256.hexdigest(request.raw)[0, 12]}.", tokens: [40, 8]) }
    end
  end
end
