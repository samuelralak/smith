# frozen_string_literal: true

require "logger"
require "stringio"

module CoreInvisibility
  # What the harness installs once per process, before any scenario: the
  # counters on the four lookups, one event subscription, and loggers with a
  # fixed line (the default carries the pid and the time).
  module Hooks
    LINE = proc { |severity, _time, program, message| "#{severity} #{program} #{message}\n" }
    COUNTED = [["Smith::Agent::Registry", :fetch!], ["Smith::Agent::Registry", :capture_bindings!],
               ["RubyLLM", :context], ["RubyLLM::Context", :new]].freeze

    class << self
      attr_reader :smith_log, :ruby_llm_log

      def install!
        Determinism.install!
        COUNTED.each { |owner, name| count(Object.const_get(owner), owner, name) }
        Smith::Events.on(Smith::Event) do |event|
          CoreInvisibility.record&.add(:events, [event.class.name, event.to_h])
        end
        install_loggers
      end

      # The lines each logger wrote since the last drain.
      def label(owner, name) = "#{owner}.#{name}"

      def drain_logs
        [smith_log, ruby_llm_log].map do |io|
          lines = io.string.lines(chomp: true)
          io.truncate(0)
          io.rewind
          lines
        end
      end

      private

      def count(target, owner, name)
        label = label(owner, name)
        target.singleton_class.prepend(Module.new do
          define_method(name) do |*arguments, **keywords, &block|
            CoreInvisibility.record&.count(label)
            super(*arguments, **keywords, &block)
          end
        end)
      end

      def install_loggers
        @smith_log = StringIO.new
        @ruby_llm_log = StringIO.new
        Smith.config.logger = Logger.new(@smith_log, formatter: LINE)
        RubyLLM.configure do |config|
          config.log_level = Logger::INFO
          config.logger = Logger.new(@ruby_llm_log, level: Logger::INFO, formatter: LINE)
        end
      end
    end
  end
end
