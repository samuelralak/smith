# frozen_string_literal: true

require "smith"
require "ruby_llm"

Dir[File.expand_path("support/**/*.rb", __dir__)].each { |file| require file }

RSpec.configure do |config|
  # Enable flags like --only-failures and --next-failure
  config.example_status_persistence_file_path = ".rspec_status"

  # Disable RSpec exposing methods globally on `Module` and `main`
  config.disable_monkey_patching!

  config.expect_with :rspec do |c|
    c.syntax = :expect
  end

  config.include ContractHelpers

  config.define_derived_metadata(file_path: %r{/spec/}) do |metadata|
    metadata[:aggregate_failures] = true
  end

  config.after(:each) do
    Smith::Events.reset!
  end
end
