# frozen_string_literal: true

require "rake"

RSpec.describe "Smith Rake tasks" do
  before(:all) do
    Rake::Application.new.tap do |app|
      Rake.application = app
      load File.expand_path("../../lib/smith/tasks/doctor.rake", __dir__)
    end
  end

  it "defines smith:doctor task" do
    expect(Rake::Task.task_defined?("smith:doctor")).to be true
  end

  it "defines smith:doctor:live task" do
    expect(Rake::Task.task_defined?("smith:doctor:live")).to be true
  end

  it "defines smith:doctor:durability task" do
    expect(Rake::Task.task_defined?("smith:doctor:durability")).to be true
  end

  it "defines smith:install task" do
    expect(Rake::Task.task_defined?("smith:install")).to be true
  end
end
