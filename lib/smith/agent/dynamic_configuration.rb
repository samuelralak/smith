# frozen_string_literal: true

module Smith
  class Agent
    module DynamicConfiguration
      attr_reader :model_block

      def model(model_id = nil, **options, &block)
        return configure_dynamic_model(model_id, options, block) if block

        @model_block = nil
        super
      end

      def model_configured?
        !chat_kwargs[:model].nil? || !@model_block.nil?
      end

      def tools(*tools, &block)
        return super unless block

        super(&wrap_runtime_block(block))
      end

      def instructions(text = nil, **prompt_locals, &block)
        return super unless block

        super(text, **prompt_locals, &wrap_runtime_block(block))
      end

      def params(**params_kwargs, &block)
        return super unless block

        super(&wrap_runtime_block(block))
      end

      def headers(**headers_kwargs, &block)
        return super unless block

        super(&wrap_runtime_block(block))
      end

      def schema(value = nil, &block)
        return super unless block

        super(&wrap_runtime_block(block))
      end

      private

      def configure_dynamic_model(model_id, options, block)
        raise ArgumentError, "model can take a string id OR a block, not both" if model_id || options.any?

        @model_block = block
        @chat_kwargs ||= {}
        @chat_kwargs.delete(:model)
      end

      def wrap_runtime_block(user_block)
        return user_block if user_block.arity.zero?

        proc do |*|
          runtime = self
          runtime.instance_exec(runtime, &user_block)
        end
      end
    end
  end
end
