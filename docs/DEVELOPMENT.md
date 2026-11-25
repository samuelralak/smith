# Developing Smith

## Verification discipline

Tests are required, but they are never enough for runtime primitive changes.
Every Smith workflow slice must also run practical gem-level execution probes.
When a host application consumes unreleased Smith changes, point that host app at
the local Smith repository and exercise the changed workflow paths in the host
environment before calling the slice complete.

## Algorithms

Smith changes must not use brute-force graph search, validation, scheduling, or
class-generation algorithms. Document the relevant time and space complexity,
prefer indexed, linear, logarithmic, or otherwise bounded approaches, and treat
an avoidable asymptotic regression as a release blocker.

## Runtime complexity

- Executable graph reachability is iterative `O(V + E)` time and `O(V)` space,
  using indexed outgoing transitions and runtime-equivalent successor rules.
- Smith-managed tool arguments are copied iteratively in `O(N + B)` time and
  `O(N + B)` bounded space for `N` expanded JSON value occurrences and `B`
  expanded encoded bytes. Reused subgraphs are charged for every serialized
  occurrence, native `Array` and `Hash` operations bypass hostile overrides, and
  every mutable container's native size is admitted before one shallow copy is
  made. Smith verifies the copy retained the admitted size before allocating or
  traversing children. One immutable dispatch collection remains authoritative
  from host admission through RubyLLM execution. The complete provider batch is
  bounded to 100 calls and 1 MiB of normalized UTF-8 call metadata. The capture
  boundary transfers temporary ownership of the provider collection and argument
  graph to Smith: callers must not mutate them concurrently. Smith detects changed
  cardinality and fails closed, but Ruby cannot prevent an unrelated writer from
  growing a caller-owned container between native size admission and the native
  copy without freezing that caller-owned object.
- Admitted tool-receipt settlement scans each batch once in `O(B)` time and
  `O(B)` state for `B` admitted Smith calls, including when an earlier terminal
  callback fails.
- Parallel execution is `O(B)` scheduling and result space for `B` branches,
  with at most `C = parallel_concurrency` active worker threads per top-level
  execution. Re-entrant fan-out inherits the same cancellation signal and uses
  only idle workers from the top-level execution context, falling back to the
  current worker when no capacity remains. Nested calls fail closed before the
  configurable nesting bound can exhaust Ruby's stack. Cancellation prevents
  queued branch bodies from starting;
  already-running branches are drained before control returns so work is never
  detached. Branch adapters must use bounded I/O and honor the cancellation
  signal. Hosts continue to own process-level concurrency and hard deadlines.
- Reservation and settlement across `L` declared budget dimensions and `D`
  operation dimensions is `O(L + D)` time and space. Receipt lookup is expected
  `O(1)`; no operation scans or copies the active receipt registry. Integer and
  Float amounts use exact decimal arithmetic internally.
- Evals statistics (`Smith::Evals::Statistics`) are `O(n log n)` time in
  their samples (each call sorts them by id) and `O(n)` space (values,
  cluster keys and index lists), except the cluster bootstrap
  (`O(B (K + n))` for `B` resamples and `K` clusters, at most `10^8` draws,
  refused above), the p-value bisection (100 interval evaluations) and
  `compare_many` (`O(m n log n + m log m)`); the incomplete beta stops
  within 2,000 iterations, the beta quantile within 400 and t's quantile
  within 200. The inputs digest streams one sample at a time.
  Canonical JSON is `O(N + sum k_i log k_i)` within 64 levels, 1,000,000
  values and 64 MiB.
- Evals datasets (`Smith::Evals::Dataset`) are `O(S + n log n)` time and
  `O(S)` space for `S` sample bytes and `n` samples (each line is scanned
  once more for repeated keys, comments and escapes the json gem may let
  through; each sample is checked, canonicalized once and sorted by id), at
  most 1,000,000 samples and 4 MiB a line; a split is `O(1)` a sample. A suite's manifest is `O(N)` in what
  it declares (at most 64 scorers and 32 gates), and its selection
  `O(n + k)` for `k` named ids or tags. Each id and digest is linear in what
  it hashes; the sample ids digest is `O(n log n)`.
- Eval stores (`Smith::Evals::Stores::Memory` and `::File`) check, write
  and read a record in `O(B)` for its `B` bytes (at most 8 MiB, 64 levels
  and 1,000,000 values), and know it by its canonical JSON in
  `O(B + sum k_i log k_i)`; reading a run's lines is `O(L)` in the file,
  and the file store's first append under a lease reads that file's ids
  once, `O(L)`, keeping `O(T)` digests for `T` lines. A lease holder cuts a
  torn last line in `O(L)` (the file is copied up to its last line feed
  and renamed over). A listing reads every header in the scope on every
  page, `O(R log R)` for `R` records, and the page's summaries; a database
  store indexes instead. Measured on a laptop: an append about 5 ms on
  macOS, most of it the drive flush (about 0.8 ms with a plain fsync), a
  lease about 8 ms and a create about 15 ms (each flushes its folders),
  records read at 4 to 5 MB/s (the strict reader), a listing page 1 to
  1.5 s at 2,000 runs.
- Retry delay calculation is `O(1)` time and space per attempt. A policy with
  `A` attempts performs at most `A` guarded operations and never materializes an
  exponential schedule.

## Commands

```bash
bundle install
bundle exec rspec
bundle exec rubocop
```
