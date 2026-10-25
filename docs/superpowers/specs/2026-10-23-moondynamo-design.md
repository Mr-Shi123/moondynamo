# MoonDynamo design

## Intent

Build a usable MoonBit client for Amazon DynamoDB's documented JSON API. The initial user is a MoonBit developer who needs basic table and item operations in an application or local integration test.

## Scope

- Public MoonBit library with typed DynamoDB attribute values that preserve number text and binary bytes.
- Signed HTTP requests using AWS Signature Version 4, including optional session token, explicit region, credentials, and endpoint override.
- Operations: create/describe table, put/get/delete item, and key query with pagination token support.
- Parse AWS errors into a structured error containing HTTP status, service error name, message, and request ID where available.
- An executable example against DynamoDB Local. Never embed real credentials.
- Unit tests for attribute serialization, request construction/signing, and response/error parsing; integration instructions for DynamoDB Local.

## Boundaries

No credential provider chain, DynamoDB Streams, transactions, batch operations, PartiQL, expression builder, or automatic schema migration in v0.1. Callers provide conditional/key expressions as strings with typed placeholder values. JavaScript is the verified runtime target; the native target compiles but its runtime validation is pending a compatible Windows C toolchain.

## Architecture

Use a pure protocol layer for value conversion, request bodies, response parsing, and signing. Keep the asynchronous HTTP transport in a small client layer. This allows deterministic tests using published SigV4 vectors and fixture responses without a cloud account. Use DynamoDB Local for end-to-end validation when available.

## Approaches considered

1. Wrap the JavaScript AWS SDK: fastest, but only JS and little MoonBit ecosystem value.
2. Implement the JSON protocol and HTTP client in MoonBit while reusing a MoonBit SigV4 library: chosen for reusable MoonBit APIs and practical scope.
3. Implement the entire AWS SDK surface: too large for a first release and unnecessary for basic use.

## Acceptance

A developer can point the client at DynamoDB Local, create a table, put an item, get it, query by key, and delete it. The same request path signs against AWS endpoints when supplied with real credentials. `moon check --target js`, `moon test --target js`, and the HTTP integration fixture pass. `moon check --target native` passes; native runtime testing remains pending on this Windows host.
