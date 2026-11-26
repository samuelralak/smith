# frozen_string_literal: true

module Smith
  module Definitions
    class Validator
      # An agent's outputs: JSON Schema in the portable core subset every
      # provider takes (research 4.5). The structure rules refuse: an
      # object root; on every object its properties, each listed in
      # `required` (optional is a union with null), and additionalProperties
      # false; a type on every schema but an anyOf or a $ref; $refs only to
      # the root's $defs, without recursion; at most 10 levels. Value
      # constraints (pattern, format, bounds, lengths, sizes) are kept, never
      # refused: Smith strips what a provider rejects and checks them after
      # the call. O(S) in the schema's nodes, each walked once.
      class OutputsCheck
        include Checks

        TEXTS = %w[description title pattern format].freeze
        NUMBERS = %w[minimum maximum exclusiveMinimum exclusiveMaximum].freeze
        COUNTS = %w[minLength maxLength minItems maxItems].freeze
        KEYWORDS = (%w[type properties required additionalProperties items enum anyOf $ref multipleOf uniqueItems] +
                    TEXTS + NUMBERS + COUNTS).freeze
        TYPES = %w[string number integer boolean array object null].freeze
        TYPE_RULE = "is #{TYPES[0..-2].join(", ")}, null, or a list of them".freeze
        DEFINITION = /\A[A-Za-z_][A-Za-z0-9_.-]{0,63}\z/
        DEFINITION_RULE = 'is a definition name: a letter or "_", then up to 63 letters, digits, ".", "_" or "-"'
        REF = %r{\A#/\$defs/([^/~]+)\z}
        REF_RULE = "names a definition in /outputs/$defs, as #/$defs/<name>"
        CLOSED = "sets additionalProperties to false, as every object must"
        LISTED = "lists each property once, and nothing else (an optional one is a union with null)"

        def initialize(problems)
          @problems = problems
        end

        def check(schema)
          return problem("/outputs", "is a schema (an object)") unless schema.is_a?(Hash)
          return problem("/outputs", "has type object at its root") unless schema["type"] == "object"

          before = @problems.size
          @definitions = definitions!(schema)
          node!(schema, "/outputs", root: true)
          @definitions.each { |name, definition| node!(definition, pointer("/outputs/$defs", name)) }
          Levels.new(@problems, @definitions).check(schema) if @problems.size == before
        end

        private

        def definitions!(schema)
          return {} unless schema.key?("$defs")
          return problem("/outputs/$defs", "is an object of schemas") || {} unless schema["$defs"].is_a?(Hash)

          schema["$defs"].select do |name, _|
            need(DEFINITION.match?(name), pointer("/outputs/$defs", name), DEFINITION_RULE)
          end
        end

        def node!(node, path, root: false)
          return problem(path, "is a schema (an object)") unless node.is_a?(Hash)

          keywords!(node, path, root)
          if node.key?("$ref") then reference!(node, path)
          elsif node.key?("anyOf") then union!(node, path)
          else typed!(node, path)
          end
        end

        def keywords!(node, path, root)
          node.each do |key, value|
            at = pointer(path, key)
            if KEYWORDS.include?(key) then constraint!(key, value, at)
            elsif key == "$defs" then need(root, at, "is only at the root")
            else problem(at, secret?(key) ? CREDENTIALS : "is not a keyword of format 1's output schemas")
            end
          end
        end

        def constraint!(key, value, path)
          if TEXTS.include?(key) then need(value.is_a?(String), path, "is a String")
          elsif NUMBERS.include?(key) then need(number?(value), path, "is a number")
          elsif COUNTS.include?(key) then need(integer?(value, 0), path, "is an Integer of at least 0")
          elsif key == "multipleOf" then need(number?(value) && value.positive?, path, "is a number above 0")
          elsif key == "uniqueItems" then need(boolean?(value), path, "is true or false")
          end
        end

        def number?(value) = value.is_a?(Integer) || value.is_a?(Float)

        def type?(type)
          return TYPES.include?(type) if type.is_a?(String)

          type.is_a?(Array) && !type.empty? && type.uniq.size == type.size && type.all? { TYPES.include?(_1) }
        end

        def reference!(node, path)
          need((node.keys - %w[$ref description title]).empty?, path, "takes only description or title beside $ref")
          name = node["$ref"].is_a?(String) && node["$ref"][REF, 1]
          need(name && @definitions.key?(name), "#{path}/$ref", REF_RULE)
        end

        def union!(node, path)
          need(!node.key?("type") && !node.key?("properties"), path, "takes no type or properties beside anyOf")
          members = node["anyOf"]
          return problem("#{path}/anyOf", "is a non-empty list of schemas") unless members.is_a?(Array) && members.any?

          members.each_with_index { |member, index| node!(member, "#{path}/anyOf/#{index}") }
        end

        def typed!(node, path)
          return problem(path, "has a type") unless node.key?("type")
          return problem("#{path}/type", TYPE_RULE) unless type?(node["type"])

          closed!(node, path) if object?(node)
          node!(node["items"], "#{path}/items") if node.key?("items")
          enum!(node["enum"], "#{path}/enum") if node.key?("enum")
        end

        def object?(node) = Array(node["type"]).include?("object") || node.key?("properties")

        def closed!(node, path)
          need(node["additionalProperties"] == false, path, CLOSED)
          properties = node["properties"]
          return problem(path, "declares its properties, as every object must") if properties.nil? || properties == {}
          return problem("#{path}/properties", "is an object of schemas") unless properties.is_a?(Hash)

          need(lists?(node["required"], properties.keys), "#{path}/required", LISTED)
          properties.each { |name, schema| node!(schema, pointer("#{path}/properties", name)) }
        end

        def lists?(required, names)
          required.is_a?(Array) && required.size == names.size && required.uniq.size == names.size &&
            (required - names).empty?
        end

        def enum!(values, path)
          scalars = values.is_a?(Array) && !values.empty? && values.none? { _1.is_a?(Hash) || _1.is_a?(Array) }
          need(scalars, path, "is a non-empty list of strings, numbers, booleans or null")
        end
      end

      # How many levels an output schema nests, a $ref counting as the
      # definition it names, and whether a definition refers to itself.
      # Each schema is walked once, within the document's depth, and
      # definitions are followed on a stack of their own, not Ruby's:
      # O(S + R) for S nodes and R references.
      class Levels
        include Checks

        RECURSIVE = "refers to itself, directly or through other definitions"

        def initialize(problems, definitions)
          @problems = problems
          @locals = definitions.transform_values { |definition| local_of(definition) }
          @levels = {}
          @open = Set.new
        end

        def check(schema)
          return unless @locals.each_key.all? { |name| @levels.key?(name) || follow(name) }

          deepest, references = local_of(schema)
          total = references.map { |name, at| at - 1 + @levels.fetch(name) }.push(deepest).max
          need(total <= MAX_SCHEMA_LEVELS, "/outputs", "nests more than #{MAX_SCHEMA_LEVELS} levels")
        end

        private

        # A schema's own deepest level, and the definitions it names, each
        # with the level of the $ref it replaces.
        def local_of(schema)
          references = []
          [local(schema, 1, references), references]
        end

        def local(node, level, references)
          if node.key?("$ref")
            references << [node["$ref"][OutputsCheck::REF, 1], level]
            return level - 1
          end

          children(node).map { local(_1, level + 1, references) }.push(level).max
        end

        def children(node) = node.fetch("properties", {}).values + [node["items"]].compact + node.fetch("anyOf", [])

        # Settles every definition `start` reaches, deepest first; nil with
        # the problem at one that refers to itself.
        def follow(start)
          stack = [[start, 0]]
          @open << start
          until stack.empty?
            target = next_target(stack)
            next settle(stack.pop.first) if target.nil?
            next if @levels.key?(target)
            return problem(pointer("/outputs/$defs", target), RECURSIVE) unless @open.add?(target)

            stack << [target, 0]
          end
          true
        end

        # The next definition the top of the stack names, moving past it.
        def next_target(stack)
          name, index = stack.last
          stack.last[1] += 1
          @locals.fetch(name).last[index]&.first
        end

        def settle(name)
          deepest, references = @locals.fetch(name)
          @levels[name] = references.map { |target, at| at - 1 + @levels.fetch(target) }.push(deepest).max
          @open.delete(name)
        end
      end
    end
  end
end
