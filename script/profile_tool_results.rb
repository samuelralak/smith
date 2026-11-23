#!/usr/bin/env ruby
# frozen_string_literal: true

# Usage: bundle exec ruby script/profile_tool_results.rb
#
# Profiles tool_results handling at various scales:
# - snapshot cost (build_run_result deep copy)
# - JSON persistence round-trip (serialize + restore)
# - parallel collector contention

require "smith"
require "json"

def measure
  start = Process.clock_gettime(Process::CLOCK_MONOTONIC)
  yield
  Process.clock_gettime(Process::CLOCK_MONOTONIC) - start
end

def build_workflow_with_entries(count, payload_size: 100)
  klass = Class.new(Smith::Workflow) do
    initial_state :idle
    state :done
    transition :finish, from: :idle, to: :done
  end

  workflow = klass.new
  payload = { "data" => "x" * payload_size, "urls" => Array.new(5) { "https://example.com/#{_1}" } }
  count.times { |i| workflow.instance_variable_get(:@tool_results) << { tool: "tool_#{i}", captured: payload.dup } }
  [klass, workflow]
end

puts "=" * 70
puts "Smith tool_results Performance Profile"
puts "=" * 70

# 1. Snapshot cost
puts "\n--- Snapshot Cost (build_run_result deep copy) ---"
[100, 1_000, 5_000].each do |count|
  _klass, workflow = build_workflow_with_entries(count)

  before_gc = GC.stat[:total_allocated_objects]
  time = measure { workflow.run! }
  after_gc = GC.stat[:total_allocated_objects]

  printf "  %<count>5d entries: %<time>.4fs, ~%<allocations>d allocations\n",
         count:, time:, allocations: after_gc - before_gc
end

# 2. JSON persistence round-trip
puts "\n--- JSON Persistence Round-Trip ---"
json = nil
[100, 1_000, 5_000].each do |count|
  klass, workflow = build_workflow_with_entries(count)

  serialize_time = measure { json = JSON.generate(workflow.to_state) }
  restore_time = measure { klass.from_state(JSON.parse(json)) }

  printf "  %<count>5d entries: serialize=%<serialize>.4fs restore=%<restore>.4fs json_bytes=%<bytes>d\n",
         count:, serialize: serialize_time, restore: restore_time, bytes: json.bytesize
end

# 3. Parallel collector contention
puts "\n--- Parallel Collector Contention ---"
[10, 50, 100].each do |branch_count|
  klass = Class.new(Smith::Workflow) do
    initial_state :idle
    state :done
    transition :finish, from: :idle, to: :done
  end

  workflow = klass.new
  collector = workflow.send(:tool_result_collector)
  threads = []

  time = measure do
    branch_count.times do |i|
      threads << Thread.new do
        5.times do |j|
          collector.call({ tool: "branch_#{i}_call_#{j}", captured: { index: i, call: j } })
        end
      end
    end
    threads.each(&:join)
  end

  total = workflow.instance_variable_get(:@tool_results).length
  expected = branch_count * 5

  status = total == expected ? "OK" : "LOSS (#{expected - total} missing)"
  printf "  %<branches>3d branches x 5 calls: %<time>.4fs, %<total>d/%<expected>d entries [%<status>s]\n",
         branches: branch_count, time:, total:, expected:, status:
end

puts "\n#{"=" * 70}\nDone."
