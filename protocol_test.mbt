///|
test "DynamoDB request signs its operation and temporary token" {
  let config : @moondynamo.Config = {
    endpoint: "http://127.0.0.1:8000",
    region: "us-east-1",
    credentials: {
      access_key_id: "AKID",
      secret_access_key: "secret",
      session_token: Some("session-token"),
    },
  }
  let request = @moondynamo.prepare_request(
    config,
    "GetItem",
    @json.parse("{\"TableName\":\"books\"}"),
    "20261023T010203Z",
  )
  assert_eq(request.url, "http://127.0.0.1:8000/")
  assert_eq(request.body, "{\"TableName\":\"books\"}")
  assert_eq(
    request.headers.get("X-Amz-Target"),
    Some("DynamoDB_20120810.GetItem"),
  )
  assert_eq(request.headers.get("X-Amz-Security-Token"), Some("session-token"))
  let auth = request.headers.get("Authorization").unwrap()
  assert_true(
    auth.contains("Credential=AKID/20261023/us-east-1/dynamodb/aws4_request"),
  )
  assert_true(
    auth.contains(
      "SignedHeaders=content-type;host;x-amz-date;x-amz-security-token;x-amz-target",
    ),
  )
}

///|
test "endpoint normalization keeps signed Host equal to transmitted Host" {
  let config : @moondynamo.Config = {
    endpoint: "https://DYNAMODB.us-east-1.amazonaws.com:443",
    region: "us-east-1",
    credentials: {
      access_key_id: "AKID",
      secret_access_key: "secret",
      session_token: None,
    },
  }
  let request = @moondynamo.prepare_request(
    config,
    "GetItem",
    @json.parse("{}"),
    "20261023T010203Z",
  )
  assert_eq(request.url, "https://dynamodb.us-east-1.amazonaws.com/")
  assert_eq(
    request.headers.get("Host"),
    Some("dynamodb.us-east-1.amazonaws.com"),
  )
}

///|
test "service error keeps type status and request ID" {
  let body = "{\"__type\":\"com.amazonaws.dynamodb.v20120810#ConditionalCheckFailedException\",\"message\":\"condition failed\"}"
  try
    @moondynamo.parse_response(400, Map([("x-amzn-RequestId", "req-1")]), body)
    |> ignore
  catch {
    @moondynamo.DynamoError::Service(status, code, message, request_id) => {
      assert_eq(status, 400)
      assert_eq(code, "ConditionalCheckFailedException")
      assert_eq(message, "condition failed")
      assert_eq(request_id, Some("req-1"))
    }
    _ => fail("unexpected DynamoDB error variant")
  } noraise {
    _ => fail("HTTP 400 must fail")
  }
}

///|
test "successful HTTP status still requires a JSON object" {
  try @moondynamo.parse_response(200, Map([]), "") |> ignore catch {
    @moondynamo.DynamoError::InvalidResponse(_) => ()
    _ => fail("unexpected error kind")
  } noraise {
    _ => fail("empty response must fail")
  }
}

///|
test "non-JSON service failure retains status and request ID" {
  try
    @moondynamo.parse_response(
      502,
      Map([("x-amzn-requestid", "req-502")]),
      "<html>upstream failure</html>",
    )
    |> ignore
  catch {
    @moondynamo.DynamoError::Service(status, code, _, request_id) => {
      assert_eq(status, 502)
      assert_eq(code, "UnknownServiceError")
      assert_eq(request_id, Some("req-502"))
    }
    _ => fail("HTTP 502 must remain a service error")
  } noraise {
    _ => fail("HTTP 502 must fail")
  }
}
