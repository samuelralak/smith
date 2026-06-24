# Configuration

There are three different configuration scopes.

### 1. Global runtime configuration: `Smith.configure`

Use this for shared runtime services:

- artifact backend
- tracing
- pricing catalog
- logger

### 2. Agent configuration: `Smith::Agent`

Use agent classes for invocation behavior:

- `model`
- `tools`
- `instructions`
- `temperature`
- `thinking`
- `budget`
- `guardrails`
- `output_schema`
- `data_volume`
- `fallback_models`
- `register_as`

### 3. Workflow configuration: `Smith::Workflow`

Use workflow classes for orchestration behavior:

- `initial_state`
- `state`
- `transition`
- `pipeline`
- `budget`
- `max_transitions`
- `guardrails`
- `context_manager`

### If You Are Unsure Where Something Goes

- "Which model should this agent use?" -> agent class
- "How do I store artifacts or emit traces?" -> `Smith.configure`
- "What happens after this step succeeds or fails?" -> workflow class
- "How many tokens/cost/tool calls can this one invocation use?" -> agent budget
- "How much total budget can the whole workflow consume?" -> workflow budget
- "Which provider credentials should the app use?" -> RubyLLM, not Smith

### Full `Smith.configure` Example

```ruby
Smith.configure do |config|
  config.artifact_store = Smith::Artifacts::Memory.new
  config.artifact_retention = 3600
  config.artifact_encryption = :none
  config.artifact_tenant_isolation = false

  config.trace_adapter = Smith::Trace::Logger
  config.trace_transitions = true
  config.trace_tool_calls = true
  config.trace_token_usage = true
  config.trace_cost = true
  config.trace_fields = {
    transition: %i[transition from to],
    tool_call: %i[tool duration]
  }
  config.trace_content = false
  config.trace_retention = 86_400
  config.trace_tenant_isolation = false

  config.pricing = {
    "gpt-4.1-nano" => {
      input_cost_per_token: 0.0000001,
      output_cost_per_token: 0.0000004
    }
  }

  config.logger = Logger.new($stdout)
end
```

### What Each `Smith.configure` Setting Is For

| Setting | What it controls | Typical first use |
| --- | --- | --- |
| `artifact_store` | Where large handoff payloads are stored | Start with `Smith::Artifacts::Memory.new` |
| `artifact_retention` | Default retention window for artifact expiry checks | Set once you have a cleanup policy |
| `artifact_encryption` | Metadata-level encryption policy flag | Leave at default until you wire a real backend |
| `artifact_tenant_isolation` | Require namespaced artifact writes | Enable in multi-tenant systems |
| `trace_adapter` | Where structural traces go | Use `Smith::Trace::Memory` or `Smith::Trace::Logger` first |
| `trace_transitions` | Emit transition traces | Usually leave on |
| `trace_tool_calls` | Emit tool call traces | Usually leave on |
| `trace_token_usage` | Emit usage traces | Useful for budget visibility |
| `trace_cost` | Emit cost traces | Useful once pricing is configured |
| `trace_fields` | Allowlist structural trace fields | Use when you want tighter trace output |
| `trace_content` | Whether content appears in traces | Leave `false` first |
| `trace_retention` | Trace retention policy hook | Useful when traces leave memory |
| `trace_tenant_isolation` | Trace multi-tenant isolation flag | Enable in multi-tenant systems |
| `pricing` | Best-known model-call cost catalog | Add once you care about `total_cost` |
| `logger` | Smith's runtime logger | Usually the first setting to add |
| `persistence_adapter` | Adapter for durable workflow state | `:redis`, `:rails_cache`, `:active_record`, `:memory`, or a custom object |
| `persistence_options` | Per-adapter options (client, namespace, model, columns) | See "Built-In Persistence Adapters" |
| `persistence_ttl` | Global TTL for persisted state (Integer/Float seconds; nil = no expiry) | Set when long-tail abandoned workflows accumulate in storage |
| `persistence_retry_policy` | Exponential-backoff policy for transient adapter I/O failures | Defaults to `{ attempts: 3, base_delay: 0.1, max_delay: 1.0 }` |
| `test_mode` | Auto-select `:memory` adapter when `persistence_adapter` is nil | Enable in `spec_helper.rb` to skip Redis/cache wiring in tests |
| `openai_api_mode` | `:auto` routes (gpt-5 family + tools + thinking) via `/v1/responses` using Smith's vendored Responses adapter (sync only; streaming over `/v1/responses` is not yet supported); `:off` drops incompatible tools instead | Leave `:auto` (default) unless you need streaming with the (gpt-5 + tools + thinking) combo, in which case set `:off` for graceful tool-dropping |
| `trace_normalizer` | Emit `:normalizer_decision` trace events from `Smith::Models::Normalizer` | Useful when debugging cross-provider request shaping |
| `ruby_llm_model_registry` | `:database` to require an AR-backed RubyLLM model registry; `:bundled` for the JSON fallback | Leave at default unless you've migrated to DB-backed |

### Recommended First Additions

Add settings in this order:

1. `config.logger`
2. `config.trace_adapter`
3. `config.artifact_store`
4. `config.pricing`

Do not start by configuring every advanced switch at once.

