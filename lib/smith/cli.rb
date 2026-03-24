# frozen_string_literal: true

require "optparse"
require_relative "doctor"

module Smith
  class CLI
    def initialize(argv)
      @argv = argv.dup
    end

    def run
      command = @argv.shift || "doctor"
      case command
      when "doctor"  then run_doctor
      when "install" then run_install
      when "version" then run_version
      when "--help", "-h" then run_help
      else
        warn "Unknown command: #{command}"
        warn usage
        1
      end
    end

    private

    def run_doctor
      options = parse_doctor_options
      report = Smith::Doctor.run(
        live: options[:live],
        durability: options[:durability],
        profile: options[:profile] || :auto
      )
      report.exit_code
    end

    def parse_doctor_options
      options = {}
      OptionParser.new do |opts|
        opts.banner = "Usage: smith doctor [options]"
        opts.on("--live", "Include live provider verification") { options[:live] = true }
        opts.on("--durability", "Include workflow durability checks") { options[:durability] = true }
        opts.on("--profile PROFILE", "Verification profile (auto, plain, rails_persistence, durable)") do |p|
          options[:profile] = p.to_sym
        end
      end.parse!(@argv)
      options
    end

    def run_install
      Smith::Doctor::Installer.run
      0
    end

    def run_version
      puts "smith #{Smith::VERSION}"
      0
    end

    def run_help
      puts usage
      0
    end

    def usage
      <<~TEXT
        Usage: smith <command> [options]

        Commands:
          doctor     Verify Smith integration (default)
          install    Scaffold Smith configuration files
          version    Show Smith version

        Doctor options:
          --live         Include live provider verification
          --durability   Include workflow durability checks
          --profile P    Verification profile (auto, plain, rails_persistence, durable)
      TEXT
    end
  end
end
