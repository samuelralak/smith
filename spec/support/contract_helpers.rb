# frozen_string_literal: true

module ContractHelpers
  def fetch_const(path)
    path.split("::").reject(&:empty?).inject(Object) do |scope, name|
      return nil unless scope.const_defined?(name, false)

      scope.const_get(name, false)
    end
  end

  def require_const(path)
    fetch_const(path) || raise(
      RSpec::Expectations::ExpectationNotMetError,
      "expected #{path} to be defined"
    )
  end

  def with_stubbed_class(name, superclass = Object, &block)
    klass = Class.new(superclass, &block)
    stub_const(name, klass)
    klass
  end
end
