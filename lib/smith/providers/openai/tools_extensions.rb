# frozen_string_literal: true

# VENDORED FROM: crmne/ruby_llm PR #770
# Pinned SHA: a84517db65d3774c6b129dc88032fe32c8dbc722
# Source path: lib/ruby_llm/providers/openai/tools.rb (rev a84517d)
# License: MIT (matches RubyLLM upstream)
#
# Re-namespaced under `Smith::Providers::OpenAI::ToolsExtensions` (the
# upstream is `RubyLLM::Providers::OpenAI::Tools`, which Smith cannot
# vendor under the same name without colliding with RubyLLM's existing
# Tools module). Functionally a verbatim copy of the methods needed by
# Smith::Providers::OpenAI::Responses; constants and helpers used only
# by the chat-completions path were intentionally omitted.
#
# RETIREMENT: this file goes away when PR #770 merges into RubyLLM
# (Smith bumps the ruby_llm dep + deletes this file + the routing
# branch that references it). Tracking: UPSTREAM_PROPOSAL.md retirement
# checklist.
#
# SYNC PROTOCOL: do NOT modify methods marked "vendored verbatim". When
# PR #770 lands changes upstream before merge, re-pin the SHA at the
# top of this file, re-fetch via `gh api repos/crmne/ruby_llm/contents/
# lib/ruby_llm/providers/openai/tools.rb?ref=<SHA>`, and replace the
# vendored block. Smith-authored helpers (none currently in this file)
# would be marked with "SMITH-AUTHORED" comments.

require "ruby_llm"

module Smith
  module Providers
    module OpenAI
      # Tool format helpers consumed by Smith::Providers::OpenAI::Responses.
      # Vendored from PR #770; namespace-only changes.
      module ToolsExtensions
        module_function

        EMPTY_PARAMETERS_SCHEMA = {
          "type" => "object",
          "properties" => {},
          "required" => [],
          "additionalProperties" => false,
          "strict" => true
        }.freeze

        def parameters_schema_for(tool)
          tool.params_schema ||
            schema_from_parameters(tool.parameters)
        end

        def schema_from_parameters(parameters)
          schema_definition = ::RubyLLM::Tool::SchemaDefinition.from_parameters(parameters)
          schema_definition&.json_schema || EMPTY_PARAMETERS_SCHEMA
        end

        def response_tool_for(tool)
          definition = {
            type: "function",
            name: tool.name,
            description: tool.description,
            parameters: parameters_schema_for(tool)
          }

          return definition if tool.provider_params.empty?

          ::RubyLLM::Utils.deep_merge(definition, tool.provider_params)
        end

        def parse_response_tool_calls(outputs)
          function_calls = ::RubyLLM::Utils.to_safe_array(outputs).select { |output| output["type"] == "function_call" }
          return nil if function_calls.empty?

          function_calls.to_h do |output|
            id = output["call_id"] || output["id"]
            [
              id,
              ::RubyLLM::ToolCall.new(
                id: id,
                name: output["name"],
                arguments: parse_response_tool_call_arguments(output)
              )
            ]
          end
        end

        def parse_response_tool_call_arguments(output)
          arguments = output["arguments"]
          return {} if arguments.nil? || arguments.empty?

          JSON.parse(arguments)
        end

        def build_response_tool_choice(tool_choice)
          case tool_choice
          when :auto, :none, :required
            tool_choice
          else
            {
              type: "function",
              name: tool_choice
            }
          end
        end
      end
    end
  end
end
