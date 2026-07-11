# frozen_string_literal: true

module Smith
  class Workflow
    module SplitStepPersistence
      module TransitionContractStructuredValues
        private

        def structured_signature(item, depth)
          case item
          when Struct then member_signature(:struct, item, depth)
          when Data then member_signature(:data, item, depth)
          when Range then range_signature(item, depth)
          when Workflow::Transition then object_signature(item, depth)
          else unsupported!(item)
          end
        end

        def member_signature(kind, object, depth)
          members = object.members.map do |name|
            [name, signature_value(object.public_send(name), depth + 1)]
          end
          [kind, object.class.name, reference_id(object), members]
        end

        def object_signature(item, depth)
          variables = item.instance_variables.sort.map do |name|
            [name, signature_value(item.instance_variable_get(name), depth + 1)]
          end
          [:object, item.class.name, item.object_id, variables]
        end

        def range_signature(range, depth)
          [
            :range,
            reference_id(range),
            signature_value(range.begin, depth + 1),
            signature_value(range.end, depth + 1),
            range.exclude_end?
          ]
        end

        def unsupported!(item)
          raise WorkflowError,
                "split-step transition contract contains unsupported value #{item.class}; " \
                "use primitives, Hash, Array, Set, Struct, Data, Range, Module, or Proc"
        end
      end
    end
  end
end
