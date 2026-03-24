# frozen_string_literal: true

module Smith
  module Doctor
    class Report
      attr_reader :checks

      def initialize
        @checks = []
      end

      def add(name:, status:, message:, detail: nil)
        @checks << Check.new(name:, status:, message:, detail:)
      end

      def passed?
        checks.none?(&:fail?)
      end

      def exit_code
        passed? ? 0 : 1
      end

      def grouped
        checks.group_by { |c| c.name.split(".").first }
      end

      def summary
        counts = checks.group_by(&:status).transform_values(&:size)
        parts = []
        parts << "#{counts.fetch(:pass, 0)} passed"
        parts << "#{counts[:warn]} warnings" if counts[:warn]
        parts << "#{counts[:fail]} failed" if counts[:fail]
        parts << "#{counts[:skip]} skipped" if counts[:skip]
        parts.join(", ")
      end
    end
  end
end
