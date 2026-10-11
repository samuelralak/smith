# Configuration

There are three different configuration scopes.

### 1. Global runtime configuration: `Smith.configure`

Use this for shared runtime services:

- artifact backend
- tracing
- pricing catalog
- run launcher (`run_launcher`, for child runs)
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
- `output_contract`, `output_repairs`
- `on_truncation`, `on_refusal`
- `data_volume`
- `fallback_models`
- `register_as`

The output macros are described in the README, Agent outputs.

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

Transition steps that start runs of their own (`map`, `call`, `spawn`) need
`Smith.config.run_launcher`; see the PERSISTENCE guide, Child Runs.

### If You Are Unsure Where Something Goes

- "Which model should this agent use?" -> agent class
- "How do I store artifacts or emit traces?" -> `Smith.configure`
- "What happens after this step succeeds or fails?" -> workflow class
- "How many tokens/cost/tool calls can this one invocation use?" -> agent budget
- "How much total budget can the whole workflow consume?" -> workflow budget
- "Which provider credentials should the app use?" -> RubyLLM, not Smith

### Provider-qualified fallback models

Fallback models are exact model/provider identities:

```ruby
fallback_models(
  { model: "claude-sonnet-4-6", provider: :anthropic },
  { model: "openai/gpt-5", provider: :openrouter }
)
```

Every fallback must name its provider. Smith does not inherit the primary
model's provider or infer one from the model id; an unqualified fallback fails
closed during agent configuration.

### Full `Smith.configure` Example

```ruby
Smith.configure do |config|
  config.artifact_store = :s3   # S3 or R2; or :active_record, :file, :memory, a store
  config.artifact_options = {
    bucket: "smith-artifacts",
    endpoint: "https://<account>.r2.cloudflarestorage.com", region: "auto",
    access_key_id: ENV.fetch("R2_ACCESS_KEY_ID"), secret_access_key: ENV.fetch("R2_SECRET_ACCESS_KEY"),
    request_checksum_calculation: "when_required", response_checksum_validation: "when_required" # R2
  }
  config.artifact_retention = 30 * 86_400
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
  config.trace_provider_calls = true
  config.trace_attribution = true

  config.pricing = Smith::Pricing.validate_catalog!(
    %w[openai gpt-4.1-nano] => {
      input_cost_per_token: 0.0000001,
      output_cost_per_token: 0.0000004,
      cache_read_cost_per_token: 0.000000025
    }
  )

  # Streamed steps (`execute Agent, stream: :answer`): a callable that takes the
  # step's info and returns its sink, or nil to stream nothing.
  config.stream_sinks = { answer: ->(info) { AnswerStream.new(info[:execution_key]) } }

  # Batch steps (`execute Agent, mode: :batch`): the host's queue of requests.
  config.batch_queue = HostBatchQueue.new

  # How long a request's hold on a workflow's budget_ledger lasts unsettled.
  config.budget_hold_ttl = 3600

  config.logger = Logger.new($stdout)
end
```

Provider-qualified model calls require provider-qualified pricing keys. Smith
also accepts the string form `"openai/gpt-4.1-nano"`. Legacy model-only keys
remain available only for calls whose provider is genuinely unknown; a
provider-qualified call never reads a model-only rate, and usage with no
applicable rate stays unpriced (a nil cost), without raising.
`Smith::Pricing.validate_catalog!` is the raising check: it rejects model-only
keys, keys that collide, non-Hash entries, optional rates that are not
non-negative Integers or Floats, and a `batch_discount` that is out of range or
sits inside a tier.

Each entry, or each tier of a tiered entry, prices `input_cost_per_token` and
`output_cost_per_token`, and optionally `cache_read_cost_per_token` and
`cache_write_cost_per_token` for input read from or written to a prompt cache,
which providers report apart from uncached input. A tier without its own cache
rate uses the entry's. An entry may also carry `batch_discount`, the fraction
taken off the cost of a call made in batch mode (`0.5` for half price). Cache
rates and the batch discount are configured per catalog and count as `0` when
absent: cache tokens then add nothing to a cost (the `:cost` trace says so with
`cache_unpriced: true`), and a batch call costs the full rate. Tiers are chosen
on a call's total input, uncached plus cache read plus cache write, so a cached
call can pass every bounded tier and stay unpriced when the last tier is
bounded. One cache write rate prices every cache lifetime; a provider that bills
longer-lived cache writes higher (Anthropic's one-hour cache) needs the rate of
the lifetime the host uses. Keys may be Symbols or Strings, as a catalog loaded
from JSON or YAML has.

### What Each `Smith.configure` Setting Is For

| Setting | What it controls | Typical first use |
| --- | --- | --- |
| `artifact_store` | Where large handoff payloads and documents are stored: `:s3` (S3, R2), `:active_record`, `:file`, `:memory`, a store or a store class | Required outside `test_mode`; a shared, durable store whenever runs wait, retry or move between processes |
| `artifact_options` | Options the named store is built with (`:s3`: `bucket:`, `prefix:`, `client:` or `region:`/`endpoint:`/credentials; `:active_record`: `model:`; `:file`: `dir:`; any: `namespace:`) | Set with `artifact_store` |
| `artifact_retention` | Default retention window for artifact expiry checks | Longer than the longest wait of any run |
| `artifact_encryption` | Metadata-level encryption policy flag | Leave at default until you wire a real backend |
| `artifact_tenant_isolation` | Require namespaced artifact writes | Enable in multi-tenant systems |
| `trace_adapter` | Where structural traces go | Use `Smith::Trace::Memory` or `Smith::Trace::Logger` first |
| `trace_transitions` | Emit transition traces | Usually leave on |
| `trace_tool_calls` | Emit tool call traces | Usually leave on |
| `trace_token_usage` | Emit usage traces | Useful for budget visibility |
| `trace_provider_calls` | Emit one timed `:provider_call` trace per provider attempt | Usually leave on |
| `trace_cost` | Emit one `:cost` trace per completed agent invocation | Emits only once pricing is configured |
| `trace_fields` | Allowlist structural trace fields | Use when you want tighter trace output |
| `trace_content` | Whether content appears in traces: `false` drops content fields, `:redacted` replaces every String and Symbol inside them, at any depth, with `"[REDACTED]"`, and `true` keeps them. The built-in adapters treat `content`, `prompt`, `response`, `args`, and `result` as content; the central policy, which runs first, masks `args` and `result`. Every other field passes unmasked, including identifiers such as model, execution key (which defaults to the persistence key), tool name, and error class, and any field a custom trace adds: drop those with `trace_fields` if they must not leave the process | Leave `false` first |
| `trace_attribution` | Merge ambient execution attribution into trace payloads | Usually leave on |
| `pricing` | Best-known model-call cost catalog | Add once you care about `total_cost` |
| `logger` | Smith's runtime logger | Usually the first setting to add |
| `batch_queue` | Takes the requests `mode: :batch` steps send: `enqueue(custom_id:, await_token:, request:, execution_key:)`, idempotent on `custom_id`; the host submits them (`Smith::Providers::Anthropic::Batches`) and resumes each run with its results | Set before any workflow batches; readiness reports a missing one |
| `response_memo` | Keeps what a step's provider calls got (`fetch(key)`, `store(key, record)`), so a step replayed after its process died reuses it instead of paying again (README, "Response memo") | Set it where replays happen: lax idempotency mode, or a host that runs a crashed step again |
| `budget_hold_ttl` | Seconds a provider request's hold on a workflow's `budget_ledger` lasts unsettled (default 3600): each hold's `expires_at` is this from now, and a batch request's is its 25-hour wait longer. Past it the request's process is taken to have died | Raise it above the longest request (its retries and stream included) |
| `budget_hold_output_tokens` | The most output tokens a request's hold on a workflow's `budget_ledger` counts (default nil: the request's own `max_tokens`, else the model's maximum). Only the hold changes, not the request; a longer reply is reconciled at what it cost | Set it when agents leave `max_tokens` unset and a small budget would refuse calls on their huge holds |
| `stream_sinks` | The sinks `execute Agent, stream: :name` steps send text to, by name: callables that take a step's info (`stream`, `execution_key`, `transition`) and return that step's sink, or nil to stream nothing | Register each name a workflow streams to; readiness reports a missing one |
| `persistence_adapter` | Adapter for durable workflow state | `:redis`, `:rails_cache`, `:active_record`, `:memory`, or a custom object |
| `persistence_options` | Per-adapter options (client, namespace, model, columns) | See "Built-In Persistence Adapters" |
| `persistence_ttl` | Global TTL for persisted state (Integer/Float seconds; nil = no expiry). `:active_record` cannot expire state, so its writes refuse a non-nil TTL (reads and deletes still work, and `smith doctor --durability` flags the combination) | Set when long-tail abandoned workflows accumulate in storage |
| `persistence_max_bytes` | The most bytes a stored workflow state may take (nil, the default: no bound). A stored run's step whose result would take it past the bound fails with `Smith::PersistedStateTooLarge` (its `key`, `bytes` and `limit`) before the result is kept, as with any error: its usage is recorded and its `on_failure` taken, so the run stays storable, strict mode included. A tool loop refused for budget does not pause into a state past it (it goes on unheld). Any other state past it is refused before anything is written. The answer that did not fit is not kept. `rails g smith:install` sets it to 1 MiB, with a CHECK a third above it on the payload column | Set it above the largest output a step keeps, with a database CHECK on the payload, so an oversized state fails as a typed step error instead of a database one |
| `persistence_retry_policy` | Exponential-backoff policy for transient adapter I/O failures | Defaults to `{ attempts: 3, base_delay: 0.1, max_delay: 1.0 }` |
| `retry_attempt_limit` | Maximum attempts accepted by workflow and persistence retry policies | Defaults to `100` |
| `parallel_branch_limit` | Maximum branches accepted by one homogeneous or heterogeneous fan-out | Defaults to `1_000` |
| `parallel_concurrency` | Maximum active branch threads within one parallel execution | Defaults to `8` |
| `parallel_nesting_limit` | Maximum re-entrant fan-out depth; hard-capped at `256` | Defaults to `64` |
| `test_mode` | Auto-select the in-process `:memory` adapter when `persistence_adapter` is nil, and an in-process artifact store when `artifact_store` is nil | Enable in `spec_helper.rb` to skip Redis/cache/bucket wiring in tests |
| `openai_api_mode` | `:auto` routes (gpt-5 family + tools + thinking) via `/v1/responses` using Smith's vendored Responses adapter, which does not stream (a streamed step gets each reply as one delta); `:off` drops incompatible tools instead | Leave `:auto` (default) unless you need token streaming with the (gpt-5 + tools + thinking) combo, in which case set `:off` for graceful tool-dropping |
| `trace_normalizer` | Emit `:normalizer_decision` trace events from `Smith::Models::Normalizer` | Useful when debugging cross-provider request shaping |
| `ruby_llm_model_registry` | `:database` to require an AR-backed RubyLLM model registry; `:bundled` for the JSON fallback | Leave at default unless you've migrated to DB-backed |

### The `:provider_call` Trace

With `trace_provider_calls` on, every provider attempt emits one
`:provider_call` trace when it ends: `model`, `provider`, `attempt_id` (shared
with the attempt's usage entries), `attempt_index` (its position in the
fallback chain), `outcome` (`:success`, `:failure`, or `:aborted`), and
`duration_ms` once the timed call started. `agent_name` is the registered name
of the agent that made the attempt, so a generator and an evaluator sharing an
optimize round stay apart. `input_tokens` and `output_tokens` total the
provider-reported usage that the attempt's usage entries record (a completed
tool-loop prefix, and a failed attempt's own reported usage); both are omitted
when the provider reported none. `input_tokens` counts uncached input only;
`cache_read_tokens` and `cache_write_tokens` are the prompt-cache input beside
it, and `thinking_tokens` are already inside `output_tokens`. `stop_reason` and
`provider_message_id` are those of the attempt's last provider response, read
from its raw body when the body is one Smith recognizes (Anthropic, OpenAI Chat
Completions and Responses, Gemini, Bedrock Converse), or from its stream when
the step streamed. Each of these is omitted when the provider did not report
it. `mode` is `:stream` for a streamed attempt, `:batch` for one answered by a
batch result, and omitted for a synchronous one; `request_changed: true` marks
a batch result whose call rendered a request other than the one sent (a date in
its prompt, data read afresh) and took the result all the same
(`on_request_change: :keep`, the default). `:token_usage` and `:cost` traces carry
`cache_read_tokens` and `cache_write_tokens` too, and `:cost` adds
`cache_unpriced: true` when cache tokens were priced at 0 for lack of a rate. A
failed or aborted attempt adds `error_class`,
and `error_cause_class` for the error's direct cause (`Exception#cause`, else a
wrapping error's `wrapped_exception`, such as the `EOFError` inside a
`Faraday::ConnectionFailed`), omitted when there is none. Class names and token
counts are metadata, never content: `trace_content false` keeps them, messages
never appear, and a `trace_fields` allowlist for `:provider_call` must name
each field it wants. Ambient attribution (`transition`, `round`, and so on)
merges in as for every trace.

### Recommended First Additions

Add settings in this order:

1. `config.logger`
2. `config.trace_adapter`
3. `config.artifact_store`
4. `config.pricing`

Do not start by configuring every advanced switch at once.
