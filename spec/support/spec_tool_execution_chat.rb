# frozen_string_literal: true

class SpecToolExecutionChat
  attr_reader :tools

  def initialize(tools)
    @tools = tools
  end

  def run_concurrently(tool_calls)
    execute_tools_concurrently(tool_calls)
  end

  def run_sequentially(tool_call) = execute_tool(tool_call)

  def run_sequential_batch(tool_calls) = handle_sequential_tool_calls(tool_calls)

  private

  def execute_tool(tool_call)
    tools.fetch(tool_call.name).call(tool_call.arguments)
  end

  def execute_tools_concurrently(tool_calls, &on_result)
    RubyLLM::ToolConcurrency.run(:threads, tool_calls, on_result:) do |tool_call|
      execute_tool(tool_call)
    end
  end

  def handle_sequential_tool_calls(tool_calls)
    tool_calls.each_value.map { execute_tool(_1) }
  end
end
