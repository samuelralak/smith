# frozen_string_literal: true

class SpecInstrumentationCollector
  attr_reader :records

  def initialize(records)
    @records = records
  end

  def instrument(name, payload)
    result = yield
    records << [name, payload.dup] if name == "chat.ruby_llm"
    result
  end
end
