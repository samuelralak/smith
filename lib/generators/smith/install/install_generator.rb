# frozen_string_literal: true

require "rails/generators"
require "rails/generators/active_record"

module Smith
  # `rails g smith:install`: the initializer, and a table and model for
  # workflow state (Smith's :active_record persistence adapter) unless
  # --skip-state-model.
  class InstallGenerator < Rails::Generators::Base
    include Rails::Generators::Migration

    # The most a PostgreSQL text column holds (1 GiB less a byte), the
    # payload's limit when no bound is set.
    UNBOUNDED_PAYLOAD = 1_073_741_823
    # The default bound: well above what one step can add to a state (a
    # map's collected results, 4 MiB; a wait's payload or a paused tool
    # loop, 1 MiB each), so it refuses runaway growth, not a run Smith built.
    MAX_STATE_BYTES = 16 * 1024 * 1024

    source_root File.expand_path("templates", __dir__)
    desc "Writes Smith's initializer, and a table and model for workflow state"

    class_option :state_model, type: :string, default: "WorkflowState",
                               desc: "The model that keeps workflow state"
    class_option :max_state_bytes, type: :numeric, default: MAX_STATE_BYTES,
                                   desc: "persistence_max_bytes, and the payload CHECK above it (0: neither)"
    class_option :skip_state_model, type: :boolean, default: false,
                                    desc: "Write only the initializer"

    def self.next_migration_number(dirname) = ActiveRecord::Generators::Base.next_migration_number(dirname)

    def check_options
      bytes = options[:max_state_bytes]
      return if bytes.is_a?(Integer) && !bytes.negative?

      raise Thor::Error, "--max-state-bytes must be a whole number of bytes (0 for no bound), got #{bytes.inspect}"
    end

    def create_smith_initializer
      template "smith.rb.tt", "config/initializers/smith.rb"
    end

    def create_state_model
      return if options[:skip_state_model]

      migration_template "create_workflow_states.rb.tt", "db/migrate/create_#{table_name}.rb"
      template "workflow_state.rb.tt", File.join("app/models", "#{state_model.underscore}.rb")
    end

    def show_next_steps
      say ""
      say "Smith installed. Next steps:", :green
      say "  1. Configure RubyLLM in config/initializers/ruby_llm.rb"
      say "  2. Run: bin/rails db:migrate" unless options[:skip_state_model]
      say "  #{options[:skip_state_model] ? 2 : 3}. Run: bin/rails smith:doctor"
      say ""
    end

    private

    def state_model = options[:state_model].camelize

    # The table's name, set on the model: a namespace's own
    # table_name_prefix cannot move it.
    def table_name = state_model.demodulize.underscore.pluralize

    def namespaces = state_model.split("::")[0...-1]

    def max_state_bytes = options[:max_state_bytes]

    # The payload CHECK's bound: past persistence_max_bytes by a third and
    # a little, so Smith's refusal comes first even for a column the host
    # encrypts (Base64 ciphertext with its headers).
    def check_bytes
      (max_state_bytes * 4 / 3) + 4096 if max_state_bytes.positive?
    end

    # The payload column's limit: MySQL picks its text type by it (TEXT
    # holds only 64 KiB); PostgreSQL refuses one past 1 GiB and otherwise
    # ignores it, as SQLite does.
    def payload_limit = [check_bytes || UNBOUNDED_PAYLOAD, UNBOUNDED_PAYLOAD].min

    # An Integer as a Ruby literal: 16_777_216.
    def literal(number) = number.to_s.gsub(/\B(?=(\d{3})+(?!\d))/, "_")
  end
end
