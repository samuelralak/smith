# Upstream proposal: Capability profiles + before_complete hook for RubyLLM

## Motivation

Smith (a workflow-first multi-agent orchestration library built on RubyLLM) currently maintains a "shadow registry" of model capabilities — pattern-based provider rules describing how each provider shapes its API payload (Anthropic Opus 4.7+ uses adaptive thinking; OpenAI gpt-5 family needs `/v1/responses` for tools+thinking; Gemini 2.5+ accepts `thinking_budget`; etc.). When the underlying RubyLLM client doesn't know these distinctions, Smith's normalizer rewrites the chat object's `@temperature`, `@thinking`, and `@params` ivars before the request leaves.

This works but requires Smith to:

1. Maintain a parallel capability registry (`Smith::Models::Inference`)
2. Mutate RubyLLM-owned chat ivars directly (`@temperature`, `@thinking`) because RubyLLM 1.15 has no `Chat#without_thinking` / `#without_temperature` public API
3. Vendor PR #770's `/v1/responses` adapter ahead of upstream merge so gpt-5 family can use tools + reasoning_effort together

A cleaner design lives upstream in RubyLLM. This proposal describes three additive changes that would let Smith retire ~400 lines of vendored code and ~6 monkey-patches.

## Proposed RubyLLM API

### 1. `RubyLLM::Chat#without_thinking` and `#without_temperature`

Smith currently does `chat.instance_variable_set(:@thinking, nil)` and `chat.instance_variable_set(:@temperature, nil)` because there's no public way to clear these. `with_thinking` requires at least one of `effort:` or `budget:`. Add the no-arg clearers:

```ruby
module RubyLLM
  class Chat
    def without_thinking
      @thinking = nil
      self
    end

    def without_temperature
      @temperature = nil
      self
    end
  end
end
```

Small additive change. Smith retires its only remaining `instance_variable_set` calls.

### 2. `RubyLLM::Capabilities::Profile` + `Model::Info#capabilities`

Add a structured capability profile to model info:

```ruby
module RubyLLM
  module Capabilities
    Profile = Data.define(
      :thinking_shape,            # :budget_tokens | :reasoning_effort | :adaptive | nil
      :accepts_temperature,
      :tools_with_thinking_native,
      :tools_with_thinking_route  # :responses | nil for OpenAI
    )

    # Public registration API. Idempotent.
    def self.register(model_id, profile)
      registry[model_id.to_s] = profile
    end

    def self.find(model_id)
      registry[model_id.to_s]
    end

    def self.registry
      @registry ||= {}
    end
  end

  class Model::Info
    attr_reader :capabilities  # RubyLLM::Capabilities::Profile?
  end
end
```

RubyLLM's `models.json` could ship default capability profiles for the models it bundles. Smith would migrate its `Smith::Models::Inference` defaults upstream as a `Capabilities.default_rules` table.

### 3. `RubyLLM::Provider.before_complete` hook

Add an extension point for per-request shaping:

```ruby
module RubyLLM
  class Provider
    # Hosts register normalizers that run AFTER chat construction but
    # BEFORE render_payload. The hook receives the chat and the
    # capabilities profile of the resolved model.
    def self.before_complete(&block)
      normalizers << block
    end

    def self.normalizers
      @normalizers ||= []
    end

    # Existing complete(...) signature unchanged. Internally invokes
    # the registered normalizers before render_payload.
  end
end
```

## What Smith looks like after upstream lands

```ruby
# lib/smith.rb (post-upstream)
# Register Smith's library-shipped pattern rules into RubyLLM's catalog
Smith::Models::Inference.rules.each do |rule|
  RubyLLM::Capabilities.register_rule(
    provider: rule.provider,
    matcher:  rule.matcher,
    profile:  rule.to_profile("anyone").to_h.except(:model_id)
  )
end

# Register Smith's normalizer as a public RubyLLM hook
RubyLLM::Provider.before_complete do |chat, profile|
  Smith::Models::Normalizer.apply!(chat, profile: profile) if profile
end
```

Smith's `Models` registry, the `Smith::Agent.chat()` override, and the `lib/smith/providers/openai/routing.rb` vendor patch all retire. What remains in Smith: the capability defaults table and the normalizer's translation logic — still Smith-owned (orchestration concerns), just consumed through a public RubyLLM hook.

## Retirement checklist

Once the upstream API ships and Smith adopts it, the following files retire:

- `lib/smith/models.rb` — becomes a thin wrapper around `RubyLLM::Capabilities`
- `lib/smith/models/profile.rb` — replaced by `RubyLLM::Capabilities::Profile`
- `lib/smith/agent.rb#chat` override — replaced by `RubyLLM::Provider.before_complete` hook
- `lib/smith/providers/openai/routing.rb` — replaced when PR #770 merges (independent track)
- `lib/smith/providers/openai/responses.rb` — same
- `lib/smith/providers/openai/tools_extensions.rb` — same

What stays Smith-owned (orchestration concerns, not provider-API concerns):

- `lib/smith/models/inference.rb` — pattern rules table; registers itself into RubyLLM via `Capabilities.register_rule`
- `lib/smith/models/normalizer.rb` — translation logic; registered via `Provider.before_complete`
- `lib/smith/tool/compatibility.rb` — tool-side compatibility checks
- The agent / workflow / tool DSLs

## Tracking

- RubyLLM PR #770 (OpenAI `/v1/responses` support) is the related upstream track. Smith's vendored `Smith::Providers::OpenAI::Responses` retires when #770 merges.
- This proposal (capability profiles + before_complete) is a separate, additive RubyLLM RFC. Once accepted, Smith files a migration PR to consume it.

## Current RubyLLM Docs Check

As of the release-prep audit, RubyLLM's official documentation describes a model
registry with model capability and pricing data, Rails DB-backed model registry
support, provider overrides, instrumentation, and concurrent tool execution.
Smith should continue treating RubyLLM as the source of truth for provider
communication and model inventory while keeping Smith-specific workflow
semantics, request shaping, and tool-compatibility policy explicit.

Release implication: before deleting Smith's model normalizer, Responses
adapter, or model-profile inference layer, verify that RubyLLM exposes the
specific public hooks Smith needs for:

- clearing incompatible temperature/thinking settings without private ivar
  mutation
- request-shaping hooks before provider payload rendering
- endpoint selection for tools plus thinking/reasoning combinations
- model capability fields that distinguish Smith's workflow-relevant cases
