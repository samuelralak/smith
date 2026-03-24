# frozen_string_literal: true

module Smith
  module Doctor
    Check = Data.define(:name, :status, :message, :detail) do
      def pass?  = status == :pass
      def fail?  = status == :fail
      def warn?  = status == :warn
      def skip?  = status == :skip
    end
  end
end
