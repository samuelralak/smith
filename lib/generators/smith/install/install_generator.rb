# frozen_string_literal: true

require "rails/generators"

module Smith
  class InstallGenerator < Rails::Generators::Base
    source_root File.expand_path("templates", __dir__)

    def create_smith_initializer
      template "smith.rb.tt", "config/initializers/smith.rb"
    end

    def show_next_steps
      say ""
      say "Smith installed. Next steps:", :green
      say "  1. Configure RubyLLM in config/initializers/ruby_llm.rb"
      say "  2. Run: bin/rails smith:doctor"
      say "  3. Define your first agent and workflow"
      say ""
    end
  end
end
