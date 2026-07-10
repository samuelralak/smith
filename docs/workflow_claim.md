# Smith::Workflow::Claim

ActiveRecord-aware atomic claim helper. Consolidates the SELECT FOR UPDATE + status-transition pattern hosts otherwise reinvent in every per-record Execution wrapper.

ActiveRecord is loaded lazily. `lib/smith/workflow/claim.rb` does NOT const-reference `::ActiveRecord` at module load — both `.atomic` and `.cas` raise `Smith::Workflow::Claim::AdapterUnavailable` only when invoked without AR present. Smith stays gem-load-time decoupled from AR.

## `.atomic` — AASM event path

```ruby
Smith::Workflow::Claim.atomic(
  ResearchSession,
  id: session.id,
  from_statuses: %w[queued],
  transition_via: :mark_processing!,
  terminal_statuses: %w[processing ready failed],
  transaction_owner: ApplicationRecord
)
```

Wraps the transition in `transaction_owner.transaction` (defaults to `model_class`). Inside the block: `lock.find(id)`, status check, then `record.public_send(transition_via)` — AASM events fire normally with all callbacks intact.

- Returns the reloaded record on success.
- Returns `nil` when current status is in `terminal_statuses` (e.g. a duplicate enqueue arriving after the original already finished).
- Raises `Smith::Workflow::Claim::UnexpectedStatus` when status is outside `from_statuses ∪ terminal_statuses` (default behavior; pass `on_unexpected_status: :ignore` or `:log` to soften).
- Raises `ArgumentError` when `transition_via:` is nil AND the model responds to `.aasm` — prevents silent AASM-callback drops.

When using cross-model transactions (e.g. AR models inherit from `ApplicationRecord`), pass `transaction_owner: ApplicationRecord` so the existing transaction scope is preserved.

## `.cas` — single-statement CAS path

```ruby
Smith::Workflow::Claim.cas(
  Post,
  id: post.id,
  from_statuses: %w[draft scheduled failed],
  to_status: "processing"
)
```

Single `update_all` with `where(status: from_statuses)`. Returns the reloaded record or `nil` if rowcount is zero. Stamps `updated_at` via the injected `now:` lambda (defaults to `-> { Time.now.utc }`).

- Does NOT invoke AASM events. AASM callbacks are skipped by design — this path is for non-AASM CAS sites (e.g. `Posts::Publish` style).
- ActiveRecord 8.x increments `lock_version` on `update_all` when the column is present. Consumer code that depends on `lock_version` should account for this — `.cas` makes no promise about lock_version semantics.

## Idempotency contract

For both strategies, calling twice with the same `id` (no concurrency) returns the claimed record on the first call and `nil` on the second, because the status is no longer in `from_statuses`. No explicit advisory lock is held.

## When to use which

- `.atomic` — the model uses AASM (or you want guards/callbacks/auxiliary timestamps to fire).
- `.cas` — the model does NOT use AASM AND you want a single-statement update.

If the model has AASM and you want to skip events, call `.cas` explicitly; if you call `.atomic` without `transition_via:` on an AASM model, you'll get an `ArgumentError` so the silent-callback-drop is impossible.

## Testing

The default spec suite boots an in-memory SQLite database and runs the tagged
Active Record strategy examples against the `ClaimableRecord` fixture model.
Package smoke tests separately verify that requiring Smith does not make Active
Record a runtime dependency.
