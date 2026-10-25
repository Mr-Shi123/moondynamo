# MoonDynamo Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Deliver a MoonBit DynamoDB client with typed items, signed requests, common operations, and a local example. JavaScript is the verified runtime target for v0.1.

**Architecture:** Separate pure DynamoDB JSON/protocol handling from async HTTP. Reuse an existing MoonBit SigV4 package if its public API supports arbitrary DynamoDB requests; otherwise implement the narrow signer with the available crypto package and AWS test vectors.

**Tech Stack:** MoonBit JavaScript target, moonbitlang/async HTTP, kaashyapan/sigv4.

**Spec:** `docs/superpowers/specs/2026-10-23-moondynamo-design.md`

## Global Constraints

- Project root is `F:/MoonBit项目/MoonBit2/MoonDynamo`.
- Module is `Mr-Shi123/moondynamo`; do not publish or use real AWS credentials.
- Keep codec and signing logic free of I/O. Native type checking is supported; native execution requires a compatible host C toolchain.
- Numeric DynamoDB values remain strings; do not round through floating point.

## Review Focus

- Binary values and sets must use base64 on the wire and round-trip correctly.
- A temporary credential's session token must be signed and sent.
- Conditional write failures and throttling errors must retain their service error type.
- `Query` must expose `LastEvaluatedKey` for callers to page without duplicate results.
- Empty or malformed service responses must fail clearly rather than returning false success.

---

### Task 1: Module and attribute codec

**Files:** `moon.mod`, `moon.pkg`, `attribute.mbt`, `attribute_test.mbt`.

**Interfaces:** Export `AttributeValue` variants for S, N, B, BOOL, NULL, M, L, SS, NS, BS; `Item` as a map of names to values; `encode_attribute` and `decode_attribute` returning/consuming `Json` with typed errors.

- [x] Write tests for string, nested map/list, binary, number precision, sets, and malformed values.
- [x] Run `moon test --target js` and confirm missing API failures.
- [x] Implement the codec and run the full JavaScript suite.

### Task 2: Signed protocol request and response

**Files:** `signing.mbt`, `protocol.mbt`, `protocol_test.mbt`.

**Interfaces:** Export `Credentials`, `Config`, and pure `prepare_request(action, payload, timestamp)` returning URI, headers, body. Decode JSON error responses to a structured `DynamoError`.

- [x] Write tests for temporary token, target header, signed-header scope, and error JSON.
- [x] Run the JavaScript suite and confirm expected failures.
- [x] Implement request preparation and response parsing; run the full suite.

### Task 3: HTTP client and item operations

**Files:** `client.mbt`, `client_wbtest.mbt`, `scripts/mock-dynamodb.mjs`.

**Interfaces:** Export `Client` with `put_item`, `get_item`, `delete_item`, `query`, `create_table`, and `describe_table`. Query returns items plus `LastEvaluatedKey`.

- [x] Write tests for payloads, response parsing, error status, and pagination.
- [x] Run JavaScript tests and confirm expected failures.
- [x] Implement the async client over `moonbitlang/async/http` and verify its requests against a local HTTP fixture that recomputes SigV4 signatures.

### Task 4: Local example and documentation

**Files:** `cmd/main/`, `README.md`, `.gitignore`.

- [x] Add a DynamoDB Local walkthrough that creates a table, writes, reads, queries, and deletes one item using the public API.
- [x] Run `moon fmt`, `moon check --target js --deny-warn`, `moon test --target js --deny-warn`, and the local example against the HTTP fixture.
- [x] Document supported operations, setup, limits, and the precise commands/results observed.

Native verification note: `moon check --target native --deny-warn` passed. `moon test --target native` failed while building `moonbitlang/async` C code with MinGW on this Windows machine, even with an ASCII-only build path. See `docs/superpowers/ledger.md`.
