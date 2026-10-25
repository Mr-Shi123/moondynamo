# MoonDynamo

[English](README.md) | [简体中文](README.zh-CN.md)

[![License: Apache-2.0](https://img.shields.io/badge/license-Apache--2.0-blue.svg)](LICENSE)

A typed Amazon DynamoDB client for MoonBit. MoonDynamo talks the DynamoDB JSON API directly and signs every request with AWS Signature Version 4, so it works against real AWS endpoints and [DynamoDB Local](https://docs.aws.amazon.com/amazondynamodb/latest/developerguide/DynamoDBLocal.html) alike — useful in MoonBit applications and in local integration tests.

## Features

- **Core operations**: `CreateTable`, `DescribeTable`, `PutItem`, `GetItem`, `DeleteItem`, and `Query`.
- **Every DynamoDB attribute type**: `S`, `N`, `B`, `BOOL`, `NULL`, `L`, `M`, `SS`, `NS`, and `BS` map to one typed `AttributeValue` enum. Numbers stay as decimal strings end to end, so no precision is lost through floating point.
- **Conditional writes and queries**: you write condition and key-condition expressions; the client sends typed expression-attribute values with them.
- **Pagination**: `Query` returns `LastEvaluatedKey`; feed it back as `exclusive_start_key` to walk a table page by page.
- **Structured errors**: service failures raise `DynamoError::Service` carrying the HTTP status, the error code, the message, and the `x-amzn-RequestId` of the failed call.
- **Local-first configuration**: endpoint, region, and credentials (including session tokens) are all explicit, so pointing at DynamoDB Local takes no extra setup.

## Requirements

- A recent [moon](https://docs.moonbitlang.com) build — verified with `0.1.20260920`. MoonDynamo targets the **JavaScript** backend and runs on Node.js.
- Optional: Java 8+ to run DynamoDB Local, or Node.js 18+ for the bundled mock server.

## Installation

From your project root:

```bash
moon add Mr-Shi123/moondynamo
```

Then import it in the `moon.pkg` of the package that uses it:

```json
import {
  "Mr-Shi123/moondynamo"
}
```

The package is available under the default alias `@moondynamo`.

## Quick start

Run the test suite and the strict lint from this repository's root:

```bash
moon test --target js
moon check --target js --deny-warn
```

The bundled end-to-end demo ([cmd/main/main.mbt](cmd/main/main.mbt)) creates a table, writes a book, reads it back, queries it, deletes it, and confirms it is gone. The table is left in place so the demo can be re-run.

**Option A — DynamoDB Local** (recommended):

```bash
docker run --rm -p 8000:8000 amazon/dynamodb-local
# in another terminal
moon run cmd/main --target js
```

**Option B — the bundled mock** — a zero-dependency fixture ([scripts/mock-dynamodb.mjs](scripts/mock-dynamodb.mjs)) that listens on `127.0.0.1:8000` without Docker. It validates each request's content type, action, and body, and **independently recomputes every SigV4 signature** before responding, then shuts down once the expected seven-step scenario has passed:

```bash
node scripts/mock-dynamodb.mjs
# in another terminal
moon run cmd/main --target js
```

Both options print `MoonDynamo local example passed` on success.

## Usage

The examples below assume a service at `127.0.0.1:8000` (DynamoDB Local or the mock) with throwaway local credentials — never embed real credentials in source code. All calls are `async`, so the snippets live inside an `async fn main`.

### Configure a client

```moonbit
let config : @moondynamo.Config = {
  endpoint: "http://127.0.0.1:8000",
  region: "us-east-1",
  credentials: {
    access_key_id: "local",
    secret_access_key: "local",
    session_token: None,
  },
}
let db = @moondynamo.Client::new(config)
```

`endpoint` is an `http://` or `https://` origin without a path (an ASCII DNS name or an IPv4 address); the client lowercases the host and drops default ports before signing. Temporary AWS credentials go in `session_token`.

### Create a table

```moonbit
try db.create_table("Books", "pk") |> ignore catch {
  @moondynamo.DynamoError::Service(_, "ResourceInUseException", _, _) => ()
  error => raise error
}
db.describe_table("Books") |> ignore
```

`create_table` makes an on-demand (pay-per-request) table with a string partition key and, via `sort_key?`, an optional string sort key. Catching `ResourceInUseException` makes re-runs idempotent.

### Write and read items

```moonbit
let item : @moondynamo.Item = Map([
  ("pk", @moondynamo.Text("book#1")),
  ("title", @moondynamo.Text("The MoonBit Book")),
  ("pages", @moondynamo.Number("128")),
  ("tags", @moondynamo.StringSet(["moonbit", "database"])),
])
db.put_item("Books", item)

let saved = db.get_item(
  "Books",
  Map([("pk", @moondynamo.Text("book#1"))]),
  consistent_read=true,
)
guard saved is Some(book) else { fail("GetItem returned no item") }
guard book.get("title") == Some(@moondynamo.Text("The MoonBit Book")) else {
  fail("GetItem returned an unexpected item")
}
```

`get_item` returns `None` when the key does not exist.

### Conditional writes

```moonbit
try db.put_item(
  "Books",
  item,
  condition_expression="attribute_not_exists(pk)",
) catch {
  @moondynamo.DynamoError::Service(
    _,
    "ConditionalCheckFailedException",
    message,
    _,
  ) => println("conditional write rejected: \{message}")
  error => raise error
}
```

You write the expression string; typed placeholder values travel in `expression_attribute_values?` — for example `Map([(":max", @moondynamo.Number("500"))])`.

### Query with pagination

```moonbit
let mut exclusive_start_key : @moondynamo.Item? = None
let mut pages = 0
while true {
  let page = db.query(
    "Books",
    "pk = :pk",
    Map([(":pk", @moondynamo.Text("book#1"))]),
    exclusive_start_key?,
    limit=1,
  )
  pages = pages + page.items.length()
  match page.last_evaluated_key {
    Some(key) => exclusive_start_key = Some(key)
    None => break
  }
}
println("query matched \{pages} item(s)")
```

The small `limit` is just to force `LastEvaluatedKey` continuation in a tiny table; drop it to get full pages. Keep calling until `last_evaluated_key` is `None`.

### Error handling

Every operation can raise; catch and inspect what you care about:

```moonbit
try db.describe_table("Books") |> ignore catch {
  @moondynamo.DynamoError::Service(status, code, message, request_id) =>
    println("HTTP \{status} \{code}: \{message} (request \{request_id})")
  error => raise error
}
```

## Attribute value types

`Item` is an alias for `Map[String, AttributeValue]`. The full wire-format coverage:

| MoonBit | DynamoDB JSON | Notes |
| --- | --- | --- |
| `Text("hi")` | `{"S": "hi"}` | UTF-8 string |
| `Number("128")` | `{"N": "128"}` | decimal text — no float rounding |
| `Binary(b)` | `{"B": "<base64>"}` | `Bytes` encoded as base64 |
| `BoolValue(true)` | `{"BOOL": true}` | |
| `NullValue` | `{"NULL": true}` | |
| `ListValue([...])` | `{"L": [...]}` | nested values |
| `ObjectValue({...})` | `{"M": {...}}` | nested document |
| `StringSet(["a"])` | `{"SS": ["a"]}` | |
| `NumberSet(["1"])` | `{"NS": ["1"]}` | decimal text |
| `BinarySet([b])` | `{"BS": ["<base64>"]}` | |

`AttributeValue` derives `Eq`, so results are easy to assert on in tests.

## Error model

```moonbit
pub(all) suberror DynamoError {
  InvalidConfig(String)
  InvalidResponse(String)
  Service(Int, String, String, String?)
}
```

- `InvalidConfig` — bad endpoint, empty region or credentials, malformed timestamp.
- `InvalidResponse` — a 2xx response the client could not parse.
- `Service(status, code, message, request_id)` — a non-2xx answer. The code is taken from the `__type` suffix (or the `code` field), e.g. `ConditionalCheckFailedException`; the message falls back from `message` to `Message`; the request ID comes from the `x-amzn-RequestId` header. Even a non-JSON error body surfaces as `Service` with the code `UnknownServiceError`, so callers always get a typed error.

## How it is tested

- **16 unit tests** (`moon test --target js`) cover attribute round-trips, request construction and signing, response and error parsing, and pagination payloads.
- **A self-verifying HTTP fixture** ([scripts/mock-dynamodb.mjs](scripts/mock-dynamodb.mjs)) exercises a real HTTP round trip and independently recomputes every SigV4 signature, so signing drift cannot pass silently.
- **Verified against DynamoDB Local 1.25.1** end to end: `CreateTable → DescribeTable → PutItem → GetItem → Query → DeleteItem → GetItem`, including conditional-write rejection with a real `ConditionalCheckFailedException` and multi-page `Query` walks through `LastEvaluatedKey`.

### Platform status

- **JavaScript** — compile, unit tests, and live HTTP calls all verified.
- **Native** — `moon check` passes. Running natively on Windows is currently blocked by a MinGW incompatibility in `moonbitlang/async`'s C sources (that dependency documents MSVC for its Windows event loop); native runtime testing is pending.

## Architecture

Two thin layers:

- **Protocol layer** (`protocol.mbt`, `attribute.mbt`) — pure functions with no I/O: they normalize the endpoint, build the DynamoDB JSON payload, sign it with [`kaashyapan/sigv4`](https://mooncakes.io/docs/kaashyapan/sigv4), and parse responses into typed values or structured errors. Purity makes the whole wire format deterministic to test.
- **Client layer** (`client.mbt`) — a small async wrapper that sends requests through [`moonbitlang/async`](https://mooncakes.io/docs/moonbitlang/async)'s HTTP client.

## Current limitations

- Credentials come from the caller — no default credential chain, no automatic refresh.
- The endpoint must be an origin without a path; no IPv6 hostnames yet.
- Value placeholders (`:name`) are supported; name placeholders (`#name`) and expression builders are not (yet).
- No Batch*, Transact*, `Scan`, Streams, PartiQL, or schema modeling yet.
- `create_table` only creates on-demand tables with string keys; other shapes need raw calls.

## License

[Apache-2.0](LICENSE). Dependencies — [moonbitlang/async](https://mooncakes.io/docs/moonbitlang/async), [moonbitlang/x](https://mooncakes.io/docs/moonbitlang/x), [kaashyapan/sigv4](https://mooncakes.io/docs/kaashyapan/sigv4) — are all Apache-2.0 as well.
