# frozen_string_literal: true

RSpec.describe "Smith::Guardrails declaration ordering contract" do
  let(:guardrails_class) { require_const("Smith::Guardrails") }

  it "preserves declaration order within each guardrail layer" do
    concrete = with_stubbed_class("SpecOrderingGuardrails", guardrails_class) do
      input :validate_schema
      input :validate_not_injection

      tool :require_idempotency_key, on: [:mutate_graph]
      tool :rate_limit, max: 10, per: :minute, on: [:web_search]

      output :validate_schema
      output :verify_urls
      output :sanitize, max_string: 5000, max_array: 10
    end

    expect(concrete.input).to eq(
      [
        { name: :validate_schema },
        { name: :validate_not_injection }
      ]
    )

    expect(concrete.tool).to eq(
      [
        { name: :require_idempotency_key, on: [:mutate_graph] },
        { name: :rate_limit, max: 10, per: :minute, on: [:web_search] }
      ]
    )

    expect(concrete.output).to eq(
      [
        { name: :validate_schema },
        { name: :verify_urls },
        { name: :sanitize, max_string: 5000, max_array: 10 }
      ]
    )
  end
end
