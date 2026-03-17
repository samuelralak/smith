# frozen_string_literal: true

RSpec.describe "Smith built-in guardrails contract" do
  it "defines the built-in URL verifier named in the architecture" do
    expect(fetch_const("Smith::Guardrails::UrlVerifier")).not_to be_nil,
                                                                 "expected Smith::Guardrails::UrlVerifier to be defined"
  end
end
