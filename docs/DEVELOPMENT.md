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
- Retry delay calculation is `O(1)` time and space per attempt. A policy with
  `A` attempts performs at most `A` guarded operations and never materializes an
  exponential schedule.

## Commands

```bash
bundle install
bundle exec rspec
bundle exec rubocop
```
