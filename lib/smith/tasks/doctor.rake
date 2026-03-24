# frozen_string_literal: true

def smith_load_environment
  Rake::Task[:environment].invoke if Rake::Task.task_defined?(:environment)
  require "smith"
  require "smith/doctor"
end

namespace :smith do
  desc "Verify Smith integration (offline)"
  task :doctor do
    smith_load_environment
    report = Smith::Doctor.run
    exit report.exit_code unless report.passed?
  end

  namespace :doctor do
    desc "Verify Smith integration with live provider call"
    task :live do
      smith_load_environment
      report = Smith::Doctor.run(live: true)
      exit report.exit_code unless report.passed?
    end

    desc "Verify Smith workflow durability"
    task :durability do
      smith_load_environment
      report = Smith::Doctor.run(durability: true)
      exit report.exit_code unless report.passed?
    end
  end

  desc "Scaffold Smith configuration files"
  task :install do
    smith_load_environment
    Smith::Doctor::Installer.run
  end
end
