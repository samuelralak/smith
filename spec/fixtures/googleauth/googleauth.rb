# frozen_string_literal: true

require "json"

# A stand-in for the googleauth gem, for specs only (Smith does not depend
# on it): RubyLLM's Vertex AI provider requires "googleauth" for its token.
# It records which of googleauth's ways it was asked for, and answers with a
# token naming what it read: a service account key's own id (googleauth
# 1.17's ServiceAccountCredentials.make_creds reads the JSON given, and, for
# a key without project_id, runs the machine's gcloud for one, which this
# stand-in refuses), or, for the application default credentials, the
# machine's own (GOOGLE_APPLICATION_CREDENTIALS, the gcloud file, the
# metadata server).
module Google
  module Auth
    class AuthorizationError < StandardError; end

    # One bearer token, applied as googleauth's credentials apply theirs.
    class Token
      def initialize(token) = @token = token
      def apply(headers) = headers.merge("Authorization" => "Bearer #{@token}")
    end

    def self.calls = @calls ||= []

    def self.get_application_default(_scopes)
      calls << :application_default
      Token.new("adc-#{ENV.fetch("GOOGLE_APPLICATION_CREDENTIALS", "metadata-server")}")
    end

    module ServiceAccountCredentials
      def self.make_creds(json_key_io:, **)
        key = JSON.parse(json_key_io.read)
        unless key["project_id"]
          Auth.calls << :gcloud
          raise "a service account key without project_id: googleauth would run the machine's gcloud for one"
        end

        Auth.calls << :service_account
        Token.new("sa-#{key.fetch("private_key_id")}")
      end
    end
  end
end
