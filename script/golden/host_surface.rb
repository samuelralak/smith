# frozen_string_literal: true

module CoreInvisibility
  # What a host's subclass of each of the four classes can collide with:
  # - its method names, less those every Object and Class has;
  # - the names Object (or, for the class side, Class) already has that it
  #   resolves elsewhere, since such an override shadows Kernel's `format`
  #   or `open` in every host body;
  # - the constants a bare name in a host's class body finds before the
  #   host's own top-level ones (those of every ancestor before Object).
  # O(A + N) for A ancestors and N names.
  module HostSurface
    CLASSES = %w[Smith::Workflow Smith::Agent Smith::Context Smith::Tool].freeze
    VISIBILITIES = %i[public protected private].freeze
    ROOTS = [Object, Kernel, BasicObject].freeze
    private_constant :VISIBILITIES, :ROOTS

    module_function

    def call = CLASSES.to_h { [_1, surface(Object.const_get(_1))] }

    def surface(klass)
      { "instance" => names(klass, Object), "singleton" => names(klass.singleton_class, Class),
        "overrides" => { "instance" => overrides(klass, Object),
                         "singleton" => overrides(klass.singleton_class, Class) },
        "constants" => constants(klass) }
    end

    def names(owner, baseline)
      VISIBILITIES.to_h do |visibility|
        reader = :"#{visibility}_instance_methods"
        [visibility.to_s, (owner.public_send(reader) - baseline.public_send(reader)).map(&:to_s).sort]
      end
    end

    def overrides(owner, baseline)
      inherited = VISIBILITIES.flat_map { baseline.public_send(:"#{_1}_instance_methods") }.uniq
      inherited.reject { owner.instance_method(_1).owner == baseline.instance_method(_1).owner }.map(&:to_s).sort
    end

    def constants(klass)
      klass.ancestors.take_while { !ROOTS.include?(_1) }.flat_map { _1.constants(false) }.uniq.map(&:to_s).sort
    end
  end
end
