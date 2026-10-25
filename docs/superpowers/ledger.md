# MoonDynamo implementation ledger

Ruling: The MoonBit 2026 scaffold places the library package at the module root and uses `moon.mod`, so the plan uses root-level source files instead of `src/` and `moon.mod.json` — this affects file layout only.

Ruling: The new Git repository's `.git` directory is read-only in this workspace, so implementation will stay as uncommitted files — no published or shared state is affected.

Ruling: JavaScript is the verified first runtime target. Native MoonBit type checking passes, but native tests on this Windows host fail while compiling `moonbitlang/async` C sources with MinGW; the dependency explicitly requires MSVC for parts of its Windows event loop. Moving build output to an ASCII-only path did not resolve these C toolchain errors.

Verification: 16 JavaScript tests passed; the local HTTP fixture validated CreateTable, DescribeTable, PutItem, GetItem, Query, DeleteItem, and another GetItem. It independently recomputed each request's AWS Signature V4 digest.

Review fixes: Normalize endpoint host and default port before signing and transport; treat omitted `Items` in a successful Query response as an empty array while preserving `LastEvaluatedKey`; retain HTTP status and request ID for non-JSON error responses. Added regression tests for all three.

## v0.2 (2026-10-25)

Ruling: v0.2 adds `update_item` (UpdateExpression with `ReturnValues` support) and expression attribute name placeholders (`expression_attribute_names`, plus `filter_expression?` on `Query`) because DynamoDB reserved words make attribute names like `status` or `size` unreachable in expressions without them. Both follow the existing caller-authored-expression pattern; no expression builder was introduced.

Ruling: Retries reuse `moonbitlang/async`'s `retry` with `ExponentialDelay(initial=100ms, factor=2, maximum=2s)` and `max_retry=2` instead of a hand-rolled backoff loop. The retry decision stays a pure, unit-tested predicate (`is_retryable`): throttle/throughput error codes (which arrive as HTTP 400) and 429/500/503 statuses; config, response-shape, and transport errors surface immediately.

Ruling: The repository is now public at github.com/Mr-Shi123/moondynamo (the earlier read-only `.git` workspace limitation no longer applies); history starts from the v0.1 feature set.

Verification: 24 JavaScript tests passed (`moon check --target js --deny-warn` clean; `moon check --target native` clean). The extended HTTP fixture validated CreateTable, DescribeTable, PutItem, GetItem, UpdateItem (ReturnValues=ALL_NEW), a FilterExpression Query via a #name placeholder, DeleteItem, and another GetItem — recomputing every SigV4 digest. The same flow ran end to end against DynamoDB Local 1.25.1, twice, covering the ResourceInUseException idempotent path.

## v0.3 (2026-10-25)

Ruling: v0.3 completes the read paths: `query` gains `index_name` (local/global secondary indexes), `descending` (ScanIndexForward=false), and `consistent_read`; a new `scan` operation mirrors query's expression, name-placeholder, and paging options. Scan was kept out of v0.1/v0.2 deliberately; it arrived once the expression layer it reuses was in place.

Ruling: The demo regression found during v0.3 (a `git restore` had reverted the v0.2 demo additions before they were committed, so commit 9509966 shipped the old demo against the upgraded fixture) was fixed by re-landing the full demo flow; the mock now also covers Scan.

Verification: 28 JavaScript tests passed (`moon check --target js --deny-warn` and `moon check --target native` clean). The fixture sequence is CreateTable, DescribeTable, PutItem, GetItem, UpdateItem, Query, Scan, DeleteItem, GetItem with independent SigV4 recomputation. Against DynamoDB Local 1.25.1 the demo ran three times and a harness verified the README snippets verbatim: a Query against a real GSI (`index_name` + `descending` + `#st` placeholder) and a filtered, paged Scan. Discovery worth remembering: DynamoDB Local 1.25.1 namespaces tables per access key — a table created via curl with credentials `fake` is invisible to a client signing with key `local`; table setup for tests must reuse the client's access key.
