# frozen_string_literal: true

require "rails/generators"
require "rails/generators/active_record"

module Smith
  # `rails g smith:install`: the initializer, and a table and model for
  # workflow state (Smith's :active_record persistence adapter) unless
  # --skip-state-model.
  class InstallGenerator < Rails::Generators::Base
    include Rails::Generators::Migration

    source_root File.expand_path("templates", __dir__)
    desc "Writes Smith's initializer, and a table and model for workflow state"

    class_option :state_model, type: :string, default: "WorkflowState",
                               desc: "The model that keeps workflow state"
    class_option :key_type, type: :string, default: "string", enum: %w[string uuid],
                            desc: "The key column's type (uuid: PostgreSQL's)"
    class_option :references, type: :string,
                              desc: "A table whose row's id is a state's key: deleting the row deletes the state. " \
                                    "Child runs (map, call, spawn) are stored under keys of their own, so the " \
                                    "launcher creates a row for each."
    class_option :max_state_bytes, type: :numeric, default: 1_048_576,
                                   desc: "persistence_max_bytes, and the payload CHECK above it (0: neither)"
    class_option :skip_state_model, type: :boolean, default: false,
                                    desc: "Write only the initializer"

    def self.next_migration_number(dirname) = ActiveRecord::Generators::Base.next_migration_number(dirname)

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

    # The table Active Record gives the model (a namespace adds nothing).
    def table_name = state_model.demodulize.underscore.pluralize

    def namespaces = state_model.split("::")[0...-1]

    def max_state_bytes = options[:max_state_bytes].to_i

    # The payload CHECK's bound: past persistence_max_bytes by a third and
    # a little, so Smith's refusal comes first even for an encrypted
    # payload (`encrypts`: Base64 ciphertext with its headers).
    def check_bytes
      (max_state_bytes * 4 / 3) + 4096 if max_state_bytes.positive?
    end

    # An Integer as a Ruby literal: 1_048_576.
    def literal(number) = number.to_s.gsub(/\B(?=(\d{3})+(?!\d))/, "_")
  end
end
