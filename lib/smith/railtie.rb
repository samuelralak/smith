# frozen_string_literal: true

module Smith
  class Railtie < ::Rails::Railtie
    rake_tasks do
      load File.expand_path("tasks/doctor.rake", __dir__)
    end
  end
end
