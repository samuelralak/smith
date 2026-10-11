# frozen_string_literal: true

require "fileutils"

module Smith
  module Doctor
    class Installer
      def self.run(io: $stdout)
        new(io:).install
      end

      def initialize(io:)
        @io = io
      end

      def install
        write_config_file
        print_next_steps
      end

      private

      def write_config_file
        path = target_path
        if File.exist?(path)
          @io.puts "  exists  #{path}"
          return
        end

        FileUtils.mkdir_p(File.dirname(path))
        File.write(path, rails? ? rails_template : plain_template)
        @io.puts "  create  #{path}"
      end

      def target_path
        rails? ? "config/initializers/smith.rb" : "config/smith.rb"
      end

      def rails?
        defined?(::Rails::Railtie)
      end

      def rails_template
        template_path = File.expand_path("../../generators/smith/install/templates/smith.rb.tt", __dir__)
        File.read(template_path)
      end

      def plain_template
        <<~RUBY
          # frozen_string_literal: true

          require "logger"
          require "smith"

          Smith.configure do |config|
            config.logger = Logger.new($stdout)
            # Host durability verification / persistence adapter options:
            # config.persistence_adapter = :cache_store
            # config.persistence_options = {
            #   store: SomeCacheStore.new,
            #   namespace: "smith"
            # }
            #
            # config.persistence_adapter = :redis
            # config.persistence_options = {
            #   redis: Redis.new(url: ENV.fetch("REDIS_URL")),
            #   namespace: "smith"
            # }
            #
            # config.persistence_adapter = :active_record
            # config.persistence_options = {
            #   model: WorkflowState,
            #   key_column: :key,
            #   payload_column: :payload
            # }
            #
            # Custom adapters are also supported if they implement:
            #   store(key, payload)
            #   fetch(key)
            #   delete(key)
            #
            # Artifacts (large outputs, attached documents) need a store that
            # outlives the process: :s3 (S3, R2) or :active_record, with
            # config.artifact_options; :memory keeps them in this process.
            # config.artifact_store = :s3
            # config.artifact_options = { bucket: "smith-artifacts", region: "us-east-1" }
            config.trace_adapter = Smith::Trace::Memory.new
          end
        RUBY
      end

      def print_next_steps
        @io.puts ""
        if rails?
          @io.puts "Smith installed. Next steps:"
          @io.puts "  1. Configure RubyLLM in config/initializers/ruby_llm.rb"
          @io.puts "  2. Run: bin/rails smith:doctor"
        else
          @io.puts "Smith configured. Next steps:"
          @io.puts "  1. Configure RubyLLM for your provider"
          @io.puts "  2. Run: smith doctor"
        end
        @io.puts "  3. Define your first agent and workflow"
        @io.puts ""
      end
    end
  end
end
