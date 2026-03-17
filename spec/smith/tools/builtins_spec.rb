# frozen_string_literal: true

RSpec.describe "Smith built-in tools contract" do
  it "defines the built-in tools namespace and documented tool entry points" do
    %w[
      Smith::Tools
      Smith::Tools::WebSearch
      Smith::Tools::UrlFetcher
      Smith::Tools::Think
    ].each do |path|
      expect(fetch_const(path)).not_to be_nil, "expected #{path} to be defined"
    end
  end
end
