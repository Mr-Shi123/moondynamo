# MoonDynamo

[English](README.md) | [简体中文](README.zh-CN.md)

[![CI](https://github.com/Mr-Shi123/moondynamo/actions/workflows/ci.yml/badge.svg)](https://github.com/Mr-Shi123/moondynamo/actions/workflows/ci.yml)
[![License: Apache-2.0](https://img.shields.io/badge/license-Apache--2.0-blue.svg)](LICENSE)

A typed Amazon DynamoDB client for MoonBit. MoonDynamo talks the DynamoDB JSON API directly and signs every request with AWS Signature Version 4, so it works against real AWS endpoints and [DynamoDB Local](https://docs.aws.amazon.com/amazondynamodb/latest/developerguide/DynamoDBLocal.html) alike — useful in MoonBit applications and in local integration tests.

## Features

- **Core operations**: `CreateTable`, `DescribeTable`, `ListTables`, `PutItem`, `GetItem`, `UpdateItem`, `DeleteItem`, `Query`, and `Scan`.
- **Batch operations**: `batch_get_item` reads up to 100 keys in one round trip and `batch_write_item` applies up to 25 puts/deletes; whatever DynamoDB could not process comes back for an explicit re-drive.
- **Every DynamoDB attribute type**: `S`, `N`, `B`, `BOOL`, `NULL`, `L`, `M`, `SS`, `NS`, and `BS` map to one typed `AttributeValue` enum. Numbers stay as decimal strings end to end, so no precision is lost through floating point.
- **Conditional writes and filtered queries**: you write condition, key-condition, and filter expressions; the client sends typed expression-attribute values with them.
- **Selective reads**: `get_item`, `batch_get_item`, `query`, and `scan` can return only the fields named by `projection_expression`, including reserved names via `expression_attribute_names`.
- **Secondary indexes**: point `query` or `scan` at any local or global secondary index with `index_name`, read oldest-first with `descending`, and force strongly consistent base-table reads with `consistent_read`.
- **Reserved-word-safe expressions**: pass `#name` placeholders through `expression_attribute_names`, so attributes called `status`, `size`, or `timestamp` are reachable from any expression.
- **Partial updates**: `update_item` runs `SET` / `ADD` / `REMOVE` expressions and can hand back the resulting attributes via `ReturnValues`.
- **Pagination**: `Query` returns `LastEvaluatedKey`; `ListTables` returns `LastEvaluatedTableName`. Feed either marker back to fetch the next page.
- **Structured errors**: service failures raise `DynamoError::Service` carrying the HTTP status, the error code, the message, and the `x-amzn-RequestId` of the failed call.
- **Automatic retries**: throttling and transient server failures — 429/500/503 statuses and codes like `ProvisionedThroughputExceededException` — are retried with capped exponential backoff (2 retries, 100 ms doubling up to 2 s) before an error ever reaches your code.
- **Local-first configuration**: endpoint, region, and credentials (including session tokens) are all explicit, so pointing at DynamoDB Local takes no extra setup.

## Requirements

- [MoonBit](https://docs.moonbitlang.com) with `moonc` **0.10.16 or newer** — verified with `moon 0.1.20261028` / `moonc 0.10.18`. MoonDynamo targets the **JavaScript** backend and runs on Node.js.
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

Check the compiler version, then check, build, and test from this repository's root:

```bash
moon version --all
moon check --target js --deny-warn
moon build --target js
moon test --target js --deny-warn
```

The bundled end-to-end demo ([cmd/main/main.mbt](cmd/main/main.mbt)) creates and lists a table, writes a book, reads it back with both full and selected fields, updates its page count with `ReturnValues`, runs a filtered query and scan with selected fields, deletes the item, and confirms it is gone. The table is left in place so the demo can be re-run.

**Option A — DynamoDB Local** (recommended):

```bash
docker run --rm -p 8000:8000 amazon/dynamodb-local
# in another terminal
moon run cmd/main --target js
```

**Option B — the bundled mock** — a zero-dependency fixture ([scripts/mock-dynamodb.mjs](scripts/mock-dynamodb.mjs)) that listens on `127.0.0.1:8000` without Docker. It validates each request's content type, action, and body, and **independently recomputes every SigV4 signature** before responding, then shuts down once the expected eleven-step scenario has passed:

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

### List tables

```moonbit
let first = db.list_tables(limit=2)
for name in first.table_names {
  println(name)
}
if first.last_evaluated_table_name is Some(cursor) {
  let next = db.list_tables(limit=2, exclusive_start_table_name=cursor)
  for name in next.table_names {
    println(name)
  }
}
```

`limit` accepts 1–100 names per page. Continue with the returned marker until it is `None`; the client rejects an out-of-range limit before sending a request. See the [AWS ListTables API](https://docs.aws.amazon.com/amazondynamodb/latest/APIReference/API_ListTables.html).

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

To receive only selected attributes, pass a projection. Use a `#name` placeholder for reserved words such as `status`:

```moonbit
let selected = db.get_item(
  "Books",
  Map([("pk", @moondynamo.Text("book#1"))]),
  projection_expression="title, #st",
  expression_attribute_names=Map([("#st", "status")]),
)
```

The result contains only the requested attributes. See the [AWS GetItem API](https://docs.aws.amazon.com/amazondynamodb/latest/APIReference/API_GetItem.html).

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

### Update items

```moonbit
let updated = db.update_item(
  "Books",
  Map([("pk", @moondynamo.Text("book#1"))]),
  "SET pages = :pages",
  expression_attribute_values=Map([(":pages", @moondynamo.Number("200"))]),
  return_values=AllNew,
)
guard updated is Some(book) && book.get("pages") == Some(@moondynamo.Number("200")) else {
  fail("UpdateItem did not apply the new page count")
}
```

The update expression is a DynamoDB `UpdateExpression` string, so `SET` / `ADD` / `REMOVE` clauses and `if_not_exists(...)` all work as documented by AWS. With `return_values` (`AllNew`, `AllOld`, `UpdatedNew`, `UpdatedOld`, or `Nothing`) the returned `Item?` carries the affected attributes; without it you get `None`.

### Reserved words and name placeholders

DynamoDB reserves hundreds of words (`status`, `size`, `name`, `timestamp`, …), so expressions must reach such attributes through `#name` placeholders. `get_item`, `batch_get_item`, `put_item`, `update_item`, `delete_item`, `query`, and `scan` all accept `expression_attribute_names?`; `get_item`, `batch_get_item`, `query`, and `scan` also take `projection_expression?`:

```moonbit
let result = db.query(
  "Books",
  "pk = :pk",
  Map([
    (":pk", @moondynamo.Text("user#1")),
    (":st", @moondynamo.Text("active")),
    (":max", @moondynamo.Number("500")),
  ]),
  filter_expression="#st = :st AND pages <= :max",
  expression_attribute_names=Map([("#st", "status")]),
  projection_expression="title",
)
for book in result.items {
  // only the title of active books with at most 500 pages
  ignore(book)
}
```

`projection_expression` controls the returned fields; it does not reduce the read capacity used for a table query. The pagination marker remains in `last_evaluated_key` even when key attributes are not projected. See the [AWS Query API](https://docs.aws.amazon.com/amazondynamodb/latest/APIReference/API_Query.html).

### Query a secondary index

`query` accepts `index_name`, so the same key-condition style works against local and global secondary indexes. `descending` flips the read order (`ScanIndexForward=false`); `consistent_read` forces a strongly consistent read (base table only — DynamoDB does not offer it on global indexes):

```moonbit
let recent = db.query(
  "Books",
  "#st = :st",
  Map([(":st", @moondynamo.Text("active"))]),
  index_name="status-index",
  descending=true,
  expression_attribute_names=Map([("#st", "status")]),
)
for book in recent.items {
  ignore(book) // newest active books first
}
```

### Scan a table

`scan` reads every item of a table or index, with the same expression, name-placeholder, projection, and paging options as `query`:

```moonbit
let mut exclusive_start_key : @moondynamo.Item? = None
while true {
  let page = db.scan(
    "Books",
    filter_expression="pages <= :max",
    expression_attribute_values=Map([(":max", @moondynamo.Number("500"))]),
    projection_expression="title, #st",
    expression_attribute_names=Map([("#st", "status")]),
    exclusive_start_key?,
    limit=100,
  )
  for book in page.items {
    ignore(book) // do something with each matching item
  }
  match page.last_evaluated_key {
    Some(key) => exclusive_start_key = Some(key)
    None => break
  }
}
```

The filter applies after `limit` is counted, so a page can come back empty while `last_evaluated_key` is still set — keep following it until `None`.

### Batch reads and writes

`batch_get_item` fetches up to 100 keys per call; keys that do not exist are simply absent from `items`, while keys DynamoDB could not process (usually throttled) come back in `unprocessed_keys` for a follow-up call. `batch_write_item` applies up to 25 puts and deletes per call and returns the requests it could not process:

```moonbit
let batch = db.batch_get_item("Books", [key1, key2, key3])
for item in batch.items {
  ignore(item)
}
let pending = batch.unprocessed_keys // re-drive these, if any

let selected_batch = db.batch_get_item(
  "Books",
  [key1, key2],
  projection_expression="pk, title, #st",
  expression_attribute_names=Map([("#st", "status")]),
)
// Include the primary key in the projection to match results to input keys.
// Re-drive selected_batch.unprocessed_keys with the same projection options.

let leftover = db.batch_write_item("Books", [
  Put(
    Map([
      ("pk", @moondynamo.Text("book#4")),
      ("pages", @moondynamo.Number("80")),
    ]),
  ),
  Delete(key1),
])
guard leftover.is_empty() else {
  fail("re-drive the requests in leftover")
}
```

A batch write is not atomic and cannot touch the same item twice in one call.
See the [AWS BatchGetItem API](https://docs.aws.amazon.com/amazondynamodb/latest/APIReference/API_BatchGetItem.html) for projection and result-order details.

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

Every operation can raise; catch and inspect what you care about. Transient failures are already retried inside the client (see *Automatic retries* above), so what surfaces is usually a real problem:

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

- **47 unit tests** (`moon test --target js`) cover attribute round-trips, request construction and signing, expression payloads with name placeholders, projected `GetItem`, `BatchGetItem`, `Query`, and `Scan` requests, `UpdateItem` payloads and response parsing, the `ReturnValues` mapping, index and scan payloads, batch payloads and limits with unprocessed-key/request parsing, `ListTables` paging and validation, response and error parsing, and the retry decision predicate.
- **A self-verifying HTTP fixture** ([scripts/mock-dynamodb.mjs](scripts/mock-dynamodb.mjs)) exercises real HTTP round trips and independently recomputes every SigV4 signature, so signing drift cannot pass silently. Its scenario includes projected `GetItem`, `BatchGetItem`, `Query`, and `Scan` calls, `ListTables`, and `UpdateItem` with `ReturnValues=ALL_NEW`.
- **Verified against DynamoDB Local 1.25.1** end to end: `CreateTable → DescribeTable → PutItem → GetItem → UpdateItem → Query → Scan → DeleteItem → GetItem`, including conditional-write rejection with a real `ConditionalCheckFailedException`, multi-page `Query` walks through `LastEvaluatedKey`, `#name` placeholders for reserved-word attributes, a `Query` against a real global secondary index (`index_name` + `descending`) plus a filtered, paged `Scan`, and `batch_get_item` / `batch_write_item` runs confirming that missing keys are absent (not unprocessed) while processed writes take effect.

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
- Value placeholders (`:name`) and name placeholders (`#name`) are supported; programmatic expression builders are not (yet).
- The retry policy is fixed — 2 retries, 100 ms doubling up to 2 s, no jitter or per-client tuning.
- No Transact*, Streams, PartiQL, or schema modeling yet. The batch helpers are single-table wrappers over the multi-table AWS wire format.
- `create_table` only creates on-demand tables with string keys; tables with indexes or other shapes need to be created out of band.

## License

[Apache-2.0](LICENSE). Dependencies — [moonbitlang/async](https://mooncakes.io/docs/moonbitlang/async), [moonbitlang/x](https://mooncakes.io/docs/moonbitlang/x), [kaashyapan/sigv4](https://mooncakes.io/docs/kaashyapan/sigv4) — are all Apache-2.0 as well.
