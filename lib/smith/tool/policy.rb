# frozen_string_literal: true

module Smith
  class Tool < RubyLLM::Tool
    module Policy
      private

      def check_privilege!(kwargs)
        privilege = self.class.capabilities&.dig(:privilege)
        return if privilege.nil? || privilege == :none

        context = kwargs[:context] || {}
        enforce_privilege!(privilege, context)
      end

      def enforce_privilege!(privilege, context)
        require_authenticated!(context) if %i[authenticated elevated].include?(privilege)
        require_elevated!(context) if privilege == :elevated
      end

      def require_authenticated!(context)
        raise ToolPolicyDenied, "privilege requires context[:user]" unless context[:user]
      end

      def require_elevated!(context)
        return if context[:role] == :elevated

        raise ToolPolicyDenied, "privilege :elevated requires context[:role] == :elevated"
      end

      def check_authorization!(kwargs)
        authorizer = self.class.authorize
        return unless authorizer

        context = kwargs[:context]
        raise ToolPolicyDenied unless authorizer.call(context)
      end
    end
  end
end
