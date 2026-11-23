# frozen_string_literal: true

# Every object reachable from some roots, for specs that look for what a
# run keeps: walked through instance variables past any override of
# `instance_variables` (RubyLLM's hides its keys there, while Ruby 4's
# `inspect` prints them), through collections and an error's cause, with
# the class that held each. Modules, procs, threads and IO are not entered.
class ReachableObjects
  include Enumerable

  NAMES = Kernel.instance_method(:instance_variables)
  READ = Kernel.instance_method(:instance_variable_get)
  OPAQUE = [Module, Proc, Method, Thread, Mutex, IO].freeze

  def initialize(roots, skip: [])
    @roots = roots
    @skip = skip
  end

  # Yields each object and the name of the class that held it.
  def each
    seen = {}.compare_by_identity
    stack = @roots.map { [_1, "a root"] }
    until stack.empty?
      object, from = stack.pop
      next if seen[object] || @skip.any? { _1.equal?(object) }

      seen[object] = true
      yield object, from
      stack.concat(inside(object).map { [_1, holder(object)] })
    end
  end

  private

  def holder(object) = object.class.name || object.class.inspect

  def inside(object)
    return [] if OPAQUE.any? { object.is_a?(_1) }

    members(object) + NAMES.bind_call(object).map { READ.bind_call(object, _1) }
  end

  def members(object)
    case object
    when Hash then object.flat_map { |key, value| [key, value] }
    when Array, Set, Struct then object.to_a
    when Data then object.to_h.values
    when Exception then [object.cause]
    else []
    end
  end
end
