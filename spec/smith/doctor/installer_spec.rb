# frozen_string_literal: true

require "smith/doctor"
require "tmpdir"

RSpec.describe Smith::Doctor::Installer do
  it "writes config/smith.rb for plain Ruby" do
    Dir.mktmpdir do |dir|
      Dir.chdir(dir) do
        io = StringIO.new
        described_class.run(io:)

        expect(File.exist?("config/smith.rb")).to be true
        expect(io.string).to include("create")
        expect(File.read("config/smith.rb")).to include("Smith.configure")
        expect(File.read("config/smith.rb")).to include("config.persistence_adapter = :cache_store")
      end
    end
  end

  it "does not overwrite an existing file" do
    Dir.mktmpdir do |dir|
      Dir.chdir(dir) do
        FileUtils.mkdir_p("config")
        File.write("config/smith.rb", "existing")

        io = StringIO.new
        described_class.run(io:)

        expect(io.string).to include("exists")
        expect(File.read("config/smith.rb")).to eq("existing")
      end
    end
  end

  it "writes config/initializers/smith.rb when Rails is detected" do
    Dir.mktmpdir do |dir|
      Dir.chdir(dir) do
        stub_const("Rails::Railtie", Class.new)
        io = StringIO.new
        described_class.run(io:)

        expect(File.exist?("config/initializers/smith.rb")).to be true
        expect(File.exist?("config/smith.rb")).to be false
        expect(File.read("config/initializers/smith.rb")).to include("Rails.logger")
        expect(File.read("config/initializers/smith.rb")).to include("config.persistence_adapter = :rails_cache")
      end
    end
  end

  it "does not create config/smith.rb in Rails mode" do
    Dir.mktmpdir do |dir|
      Dir.chdir(dir) do
        stub_const("Rails::Railtie", Class.new)
        io = StringIO.new
        described_class.run(io:)

        expect(File.exist?("config/smith.rb")).to be false
      end
    end
  end

  it "prints next steps" do
    Dir.mktmpdir do |dir|
      Dir.chdir(dir) do
        io = StringIO.new
        described_class.run(io:)

        expect(io.string).to include("Next steps")
        expect(io.string).to include("smith doctor")
      end
    end
  end
end
