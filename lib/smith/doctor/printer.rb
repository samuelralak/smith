# frozen_string_literal: true

module Smith
  module Doctor
    class Printer
      CLEAR  = "\e[0m"
      BOLD   = "\e[1m"
      RED    = "\e[31m"
      GREEN  = "\e[32m"
      YELLOW = "\e[33m"
      CYAN   = "\e[36m"
      WHITE  = "\e[37m"

      ICONS = { pass: "\u2713", fail: "\u2717", warn: "!", skip: "-" }.freeze
      COLORS = { pass: GREEN, fail: RED, warn: YELLOW, skip: CYAN }.freeze

      def initialize(report, io: $stdout)
        @report = report
        @io = io
      end

      def print
        @io.puts colorize("\nSmith Doctor\n", BOLD, WHITE)
        print_grouped_checks
        print_summary
      end

      private

      def print_grouped_checks
        @report.grouped.each do |group, checks|
          @io.puts colorize("  #{format_group(group)}", BOLD, WHITE)
          checks.each { |c| print_check(c) }
          @io.puts
        end
      end

      def print_check(check)
        icon = ICONS.fetch(check.status)
        color = COLORS.fetch(check.status)
        @io.puts "    #{colorize(icon, color)} #{check.message}"
        @io.puts "      #{colorize(check.detail, CYAN)}" if check.detail
      end

      def print_summary
        color = @report.passed? ? GREEN : RED
        @io.puts colorize("  #{@report.summary}", BOLD, color)
        @io.puts
      end

      def format_group(group)
        group.split("_").map(&:capitalize).join(" ")
      end

      def colorize(text, *codes)
        return text.to_s unless @io.respond_to?(:tty?) && @io.tty? && ENV["NO_COLOR"].nil?

        "#{codes.join}#{text}#{CLEAR}"
      end
    end
  end
end
