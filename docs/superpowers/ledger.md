# MoonDynamo implementation ledger

Ruling: The MoonBit 2026 scaffold places the library package at the module root and uses `moon.mod`, so the plan uses root-level source files instead of `src/` and `moon.mod.json` — this affects file layout only.

Ruling: The new Git repository's `.git` directory is read-only in this workspace, so implementation will stay as uncommitted files — no published or shared state is affected.

Ruling: JavaScript is the verified first runtime target. Native MoonBit type checking passes, but native tests on this Windows host fail while compiling `moonbitlang/async` C sources with MinGW; the dependency explicitly requires MSVC for parts of its Windows event loop. Moving build output to an ASCII-only path did not resolve these C toolchain errors.

Verification: 16 JavaScript tests passed; the local HTTP fixture validated CreateTable, DescribeTable, PutItem, GetItem, Query, DeleteItem, and another GetItem. It independently recomputed each request's AWS Signature V4 digest.

Review fixes: Normalize endpoint host and default port before signing and transport; treat omitted `Items` in a successful Query response as an empty array while preserving `LastEvaluatedKey`; retain HTTP status and request ID for non-JSON error responses. Added regression tests for all three.
