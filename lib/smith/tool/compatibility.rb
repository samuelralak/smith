# frozen_string_literal: true

module Smith
  class Tool
    # Compatibility spec for a Tool class. Built by Tool.compatible_with(...)
    # and consulted by Smith::Models::Normalizer when deciding whether
    # to route, drop, or pass through a tool.
    #
    # Spec shape (frozen Hash):
    #   providers: Set[Symbol]?,            # allowlist; nil = all allowed
    #   endpoints: Hash[Symbol => Set],     # per-provider endpoint constraints
    #   except:    Hash[Symbol => Set]?     # exception list (overrides allow)
    #
    # Tools that don't declare compatible_with are universally compatible
    # — Compatibility.allows?(nil, profile) returns true.
    module Compatibility
      module_function

      # Parses the DSL invocation:
      #   compatible_with :anthropic
      #   compatible_with :anthropic, :gemini, openai: :responses
      #   compatible_with except: { openai: :chat_completions }
      def parse(positional, except:, **provider_endpoints)
        providers_arg = positional + provider_endpoints.keys
        providers = if providers_arg.empty?
                      nil
                    else
                      providers_arg.map(&:to_sym).to_set
                    end
        endpoints = provider_endpoints.transform_values { |v| Array(v).map(&:to_sym).to_set }
        except_set = except&.transform_values { |v| Array(v).map(&:to_sym).to_set }

        {
          providers: providers,
          endpoints: endpoints,
          except: except_set
        }.freeze
      end

      # Returns true if the (provider, endpoint) combination is allowed
      # by spec. `effective_endpoint` defaults to profile.endpoint_mode
      # but callers (e.g., Smith::Models::Normalizer) can override when
      # user policy downgrades the endpoint — e.g., a profile with
      # tools_with_thinking_route: :responses still has its tools checked
      # against :chat_completions when Smith.config.openai_api_mode is
      # :off (no routing).
      #
      # spec == nil => universally compatible (no compatible_with declared).
      def allows?(spec, profile, effective_endpoint: nil)
        return true if spec.nil?

        provider = profile.provider
        endpoint = effective_endpoint || profile.endpoint_mode

        # exception list: explicit deny wins
        if (excluded = spec[:except]&.[](provider)) && excluded.include?(endpoint)
          return false
        end

        # allowlist by provider (nil = all allowed)
        return false if spec[:providers] && !spec[:providers].include?(provider)

        # endpoint constraint when present for the matched provider
        if (allowed_endpoints = spec[:endpoints][provider])
          return allowed_endpoints.include?(endpoint)
        end

        true
      end
    end
  end
end
